package server

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type userProviderDefinition struct {
	DefaultBaseURL       string            `json:"default_base_url"`
	ProfileID            string            `json:"profile_id"`
	AADVersion           string            `json:"aad_version"`
	MaxKeyBytes          int               `json:"max_key_bytes"`
	MaxModelLength       int               `json:"max_model_length"`
	MaxBaseURLLength     int               `json:"max_base_url_length"`
	KeyBytes             int               `json:"key_bytes"`
	NonceBytes           int               `json:"nonce_bytes"`
	TagBytes             int               `json:"tag_bytes"`
	TestTimeoutMS        int               `json:"test_timeout_ms"`
	TestMaxResponseBytes int64             `json:"test_max_response_bytes"`
	ContextWindowTokens  int64             `json:"context_window_tokens"`
	MaxOutputTokens      int64             `json:"max_output_tokens"`
	SQL                  map[string]string `json:"sql"`
}

var userProviderContract = func() userProviderDefinition {
	var definition userProviderDefinition
	if json.Unmarshal(contracts.AIUserProvider, &definition) != nil || definition.DefaultBaseURL == "" ||
		definition.ProfileID == "" || definition.AADVersion == "" || definition.KeyBytes != 32 ||
		definition.NonceBytes != 12 || definition.TagBytes != 16 || definition.MaxKeyBytes < 1 ||
		definition.MaxModelLength < 1 || definition.MaxBaseURLLength < 1 || definition.TestTimeoutMS < 1 ||
		definition.TestMaxResponseBytes < 1 || definition.ContextWindowTokens <= definition.MaxOutputTokens {
		panic("invalid AI user provider contract")
	}
	return definition
}()

var (
	errUserProviderInvalid     = errors.New("invalid personal AI provider input")
	errUserProviderReconnect   = errors.New("personal AI provider needs reconnecting")
	errUserProviderUnavailable = errors.New("personal AI provider unavailable")
	errUserProviderMissing     = errors.New("personal AI provider missing")
	userProviderModelPattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$`)
)

const maxUserProviderRevision int64 = 999999999999999

type userProviderSettings struct {
	provided string
	key      cipher.AEAD
}

func configuredUserProvider(get func(string) string) userProviderSettings {
	settings := userProviderSettings{provided: normalizedUserProviderURL(get("AI_USER_PROVIDER_URL"))}
	encoded := strings.TrimSpace(get("AI_USER_PROVIDER_SECRET_B64"))
	key, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(key) != userProviderContract.KeyBytes || base64.StdEncoding.EncodeToString(key) != encoded {
		return settings
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err == nil {
		settings.key, _ = cipher.NewGCM(block)
	}
	return settings
}

func normalizedUserProviderURL(raw string) string {
	value := strings.TrimSpace(raw)
	if !ai.ValidHTTPBaseURL(value) || strings.ContainsFunc(value, func(ch rune) bool { return ch > 0x7e }) {
		return ""
	}
	value = strings.TrimRight(value, "/")
	if len(value) > userProviderContract.MaxBaseURLLength {
		return ""
	}
	return value
}

func (s userProviderSettings) url(preset string) string {
	switch preset {
	case "default":
		return userProviderContract.DefaultBaseURL
	case "provided":
		return s.provided
	default:
		return ""
	}
}

func validUserProviderModel(model string) bool {
	return len(model) <= userProviderContract.MaxModelLength && userProviderModelPattern.MatchString(model)
}

func validUserProviderKey(key string) bool {
	return key != "" && len(key) <= userProviderContract.MaxKeyBytes && !strings.ContainsFunc(key, func(ch rune) bool { return ch < 0x21 || ch > 0x7e })
}

type userProviderInput struct {
	Preset  string
	Model   string
	Enabled bool
	APIKey  *string `json:"-"`
}

func (userProviderInput) String() string   { return "userProviderInput [redacted]" }
func (userProviderInput) GoString() string { return "userProviderInput [redacted]" }

func parseUserProviderInput(data []byte) (userProviderInput, error) {
	decoded, valid := ai.DecodeScalarJSON(data, 4)
	body, isObject := decoded.(map[string]any)
	if !valid || !isObject || hasTooManyJSONMembers(data, len(body)) {
		return userProviderInput{}, errUserProviderInvalid
	}
	preset, _ := body["preset"].(string)
	model, _ := body["model"].(string)
	enabled, boolean := body["enabled"].(bool)
	if (preset != "default" && preset != "provided") || !validUserProviderModel(model) || !boolean {
		return userProviderInput{}, errUserProviderInvalid
	}
	input := userProviderInput{Preset: preset, Model: model, Enabled: enabled}
	fields := 3
	if raw, present := body["api_key"]; present {
		key, ok := raw.(string)
		if !ok || !validUserProviderKey(key) {
			return userProviderInput{}, errUserProviderInvalid
		}
		fields++
		input.APIKey = &key
	}
	if len(body) != fields {
		return userProviderInput{}, errUserProviderInvalid
	}
	return input, nil
}

type userProviderRecord struct {
	Preset    string
	BaseURL   string
	Model     string
	SecretBox string `json:"-"`
	Enabled   bool
	Revision  int64
}

func (userProviderRecord) String() string   { return "userProviderRecord [redacted]" }
func (userProviderRecord) GoString() string { return "userProviderRecord [redacted]" }

func userProviderAAD(owner int64, preset, baseURL string) []byte {
	return []byte(userProviderContract.AADVersion + "\n" + strconv.FormatInt(owner, 10) + "\n" + preset + "\n" + baseURL)
}

func (s userProviderSettings) open(owner int64, record *userProviderRecord) (string, error) {
	if s.key == nil {
		return "", errUserProviderUnavailable
	}
	if current := s.url(record.Preset); current == "" || record.BaseURL != current {
		return "", errUserProviderReconnect
	}
	prefixSize, tagSize := userProviderContract.NonceBytes, userProviderContract.TagBytes
	maxBoxSize := prefixSize + userProviderContract.MaxKeyBytes + tagSize
	if len(record.SecretBox) > base64.RawURLEncoding.EncodedLen(maxBoxSize) {
		return "", errUserProviderReconnect
	}
	box, err := base64.RawURLEncoding.Strict().DecodeString(record.SecretBox)
	if err != nil || len(box) <= prefixSize+tagSize || len(box) > maxBoxSize || base64.RawURLEncoding.EncodeToString(box) != record.SecretBox {
		return "", errUserProviderReconnect
	}
	data, err := s.key.Open(nil, box[:prefixSize], box[prefixSize:], userProviderAAD(owner, record.Preset, record.BaseURL))
	defer clear(data)
	if err != nil || !validUserProviderKey(string(data)) {
		return "", errUserProviderReconnect
	}
	return string(data), nil
}

func (s userProviderSettings) update(owner int64, input userProviderInput, previous *userProviderRecord) (userProviderRecord, error) {
	if s.key == nil {
		return userProviderRecord{}, errUserProviderUnavailable
	}
	baseURL := s.url(input.Preset)
	if baseURL == "" || !validUserProviderModel(input.Model) {
		return userProviderRecord{}, errUserProviderInvalid
	}
	record := userProviderRecord{Preset: input.Preset, BaseURL: baseURL, Model: input.Model, Enabled: input.Enabled, Revision: 1}
	if previous != nil {
		if previous.Revision < 1 || previous.Revision >= maxUserProviderRevision {
			return userProviderRecord{}, errUserProviderUnavailable
		}
		record.Revision = previous.Revision + 1
	}
	if input.APIKey == nil {
		if previous == nil {
			return userProviderRecord{}, errUserProviderInvalid
		}
		if previous.Preset != input.Preset || previous.BaseURL != baseURL {
			return userProviderRecord{}, errUserProviderReconnect
		}
		if _, err := s.open(owner, previous); err != nil {
			return userProviderRecord{}, err
		}
		record.SecretBox = previous.SecretBox
		return record, nil
	}
	if !validUserProviderKey(*input.APIKey) {
		return userProviderRecord{}, errUserProviderInvalid
	}
	nonce := make([]byte, userProviderContract.NonceBytes)
	if _, err := rand.Read(nonce); err != nil {
		return userProviderRecord{}, errUserProviderUnavailable
	}
	box := s.key.Seal(nonce, nonce, []byte(*input.APIKey), userProviderAAD(owner, record.Preset, record.BaseURL))
	record.SecretBox = base64.RawURLEncoding.EncodeToString(box)
	return record, nil
}

type userProviderPreset struct {
	ID      string `json:"id"`
	BaseURL string `json:"base_url"`
}

type userProviderMetadata struct {
	Preset            string `json:"preset"`
	Model             string `json:"model"`
	Enabled           bool   `json:"enabled"`
	KeyConfigured     bool   `json:"key_configured"`
	Revision          int64  `json:"revision"`
	ReconnectRequired bool   `json:"reconnect_required"`
}

type userProviderResponse struct {
	SetupAvailable bool                  `json:"setup_available"`
	Presets        []userProviderPreset  `json:"presets"`
	Config         *userProviderMetadata `json:"config"`
}

func (s userProviderSettings) response(owner int64, record *userProviderRecord) userProviderResponse {
	result := userProviderResponse{SetupAvailable: s.key != nil, Presets: []userProviderPreset{{ID: "default", BaseURL: s.url("default")}}}
	if s.provided != "" {
		result.Presets = append(result.Presets, userProviderPreset{ID: "provided", BaseURL: s.provided})
	}
	if record != nil && s.key != nil {
		_, err := s.open(owner, record)
		result.Config = &userProviderMetadata{Preset: record.Preset, Model: record.Model, Enabled: record.Enabled,
			KeyConfigured: true, Revision: record.Revision, ReconnectRequired: err != nil}
	}
	return result
}
