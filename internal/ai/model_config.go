package ai

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// Selection is an internal, detached routing snapshot, not a public API response.
type Selection struct {
	ConfigurationRevision int64    `json:"configurationRevision"`
	Role                  string   `json:"role"`
	ProfileID             string   `json:"profileId"`
	ProviderID            string   `json:"providerId"`
	Adapter               string   `json:"adapter"`
	BaseURL               string   `json:"baseUrl"`
	Model                 string   `json:"model"`
	ModelVersion          string   `json:"modelVersion,omitempty"`
	APIKeyEnv             *string  `json:"apiKeyEnv"`
	Capabilities          []string `json:"capabilities"`
	ContextWindowTokens   int64    `json:"contextWindowTokens"`
	MaxOutputTokens       int64    `json:"maxOutputTokens"`
}

// Stable errors deliberately contain no configuration data or parser diagnostics.
var (
	ErrInvalidConfiguration  = errors.New("INVALID_CONFIGURATION")
	ErrUnknownRole           = errors.New("UNKNOWN_ROLE")
	ErrUnsupportedCapability = errors.New("UNSUPPORTED_CAPABILITY")
	ErrStaleConfiguration    = errors.New("STALE_CONFIGURATION")
	ErrRevisionReused        = errors.New("REVISION_REUSED")
)

type ModelRouter struct {
	mu     sync.RWMutex
	config configuration
}

type configuration struct {
	revision   int64
	selections map[string]Selection
}

type provider struct {
	ID        string  `json:"id"`
	Adapter   string  `json:"adapter"`
	BaseURL   string  `json:"baseUrl"`
	APIKeyEnv *string `json:"apiKeyEnv"`
}

type model struct {
	ID                  string   `json:"id"`
	ProviderID          string   `json:"providerId"`
	Model               string   `json:"model"`
	ModelVersion        *string  `json:"modelVersion"`
	Capabilities        []string `json:"capabilities"`
	ContextWindowTokens integer  `json:"contextWindowTokens"`
	MaxOutputTokens     integer  `json:"maxOutputTokens"`
}

// integer accepts the integral JSON number forms shared with JavaScript.
type integer int64

const maxStoredModelRevision = 999999999999999

func (n *integer) UnmarshalJSON(data []byte) error {
	if len(data) == 0 || (data[0] != '-' && (data[0] < '0' || data[0] > '9')) {
		return ErrInvalidConfiguration
	}
	f, err := strconv.ParseFloat(string(data), 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) || f != math.Trunc(f) || f < 1 || f > 9007199254740991 {
		return ErrInvalidConfiguration
	}
	*n = integer(f)
	return nil
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
var modelVersionPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`)

func ValidModelVersion(value string) bool { return modelVersionPattern.MatchString(value) }

var envReference = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
var hostLabel = regexp.MustCompile(`^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$`)
var numericHostLabel = regexp.MustCompile(`^(?:[0-9]+|0[xX][0-9A-Fa-f]+)$`)
var roleNames = []string{"knowledge", "writing", "agent", "moderation"}

func NewModelRouter(configJSON []byte) (*ModelRouter, error) {
	c, err := parseConfiguration(configJSON)
	if err != nil {
		return nil, err
	}
	return &ModelRouter{config: c}, nil
}

// Select returns an independent snapshot; it performs no inference or I/O.
func (r *ModelRouter) Select(role string, requiredCapabilities []string) (Selection, error) {
	if !isRole(role) {
		return Selection{}, ErrUnknownRole
	}
	if !validCapabilities(requiredCapabilities) {
		return Selection{}, ErrUnsupportedCapability
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.config.selections[role]
	if !ok {
		return Selection{}, ErrInvalidConfiguration
	}
	for _, capability := range requiredCapabilities {
		if !contains(s.Capabilities, capability) {
			return Selection{}, ErrUnsupportedCapability
		}
	}
	return cloneSelection(s), nil
}

// Replace validates and publishes the complete configuration while holding the
// write lock, so concurrent compare-and-replace calls cannot partially apply.
func (r *ModelRouter) Replace(nextJSON []byte, expectedRevision int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if expectedRevision != r.config.revision {
		return ErrStaleConfiguration
	}
	next, err := parseConfiguration(nextJSON)
	if err != nil {
		return err
	}
	if next.revision <= r.config.revision {
		return ErrRevisionReused
	}
	r.config = next
	return nil
}

func cloneSelection(s Selection) Selection {
	s.Capabilities = append([]string{}, s.Capabilities...)
	if s.APIKeyEnv != nil {
		value := *s.APIKeyEnv
		s.APIKeyEnv = &value
	}
	return s
}

// object enforces exact, case-sensitive fields and required non-null values.
func object(data json.RawMessage, required []string, optional ...string) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	if first, err := decoder.Token(); err != nil || first != json.Delim('{') {
		return nil, ErrInvalidConfiguration
	}
	fields := make(map[string]json.RawMessage)
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok || (!contains(required, key) && !contains(optional, key)) {
			return nil, ErrInvalidConfiguration
		}
		if _, exists := fields[key]; exists {
			return nil, ErrInvalidConfiguration
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, ErrInvalidConfiguration
		}
		fields[key] = value
	}
	if last, err := decoder.Token(); err != nil || last != json.Delim('}') {
		return nil, ErrInvalidConfiguration
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, ErrInvalidConfiguration
	}
	for _, key := range required {
		value, ok := fields[key]
		if !ok || string(value) == "null" {
			return nil, ErrInvalidConfiguration
		}
	}
	return fields, nil
}

func parseConfiguration(data []byte) (configuration, error) {
	invalid := func() (configuration, error) { return configuration{}, ErrInvalidConfiguration }
	if len(data) > 65536 || !utf8.Valid(data) || !scalarJSONEscapes(data) {
		return invalid()
	}
	fields, err := object(data, []string{"schemaVersion", "revision", "providers", "models", "bindings"})
	if err != nil {
		return invalid()
	}
	var schemaVersion, revision integer
	if json.Unmarshal(fields["schemaVersion"], &schemaVersion) != nil || schemaVersion != 1 ||
		json.Unmarshal(fields["revision"], &revision) != nil || revision > maxStoredModelRevision {
		return invalid()
	}
	var rawProviders, rawModels []json.RawMessage
	if json.Unmarshal(fields["providers"], &rawProviders) != nil || len(rawProviders) == 0 || json.Unmarshal(fields["models"], &rawModels) != nil || len(rawModels) == 0 {
		return invalid()
	}
	providers := make(map[string]provider, len(rawProviders))
	for _, raw := range rawProviders {
		if _, err := object(raw, []string{"id", "adapter", "baseUrl"}, "apiKeyEnv"); err != nil {
			return invalid()
		}
		var p provider
		if json.Unmarshal(raw, &p) != nil || !identifier.MatchString(p.ID) || (p.Adapter != "ollama" && p.Adapter != "openai-compatible") || !ValidHTTPBaseURL(p.BaseURL) {
			return invalid()
		}
		if _, exists := providers[p.ID]; exists {
			return invalid()
		}
		if p.APIKeyEnv != nil {
			if *p.APIKeyEnv == "" {
				p.APIKeyEnv = nil
			} else if !envReference.MatchString(*p.APIKeyEnv) {
				return invalid()
			}
		}
		p.BaseURL = strings.TrimRight(p.BaseURL, "/")
		providers[p.ID] = p
	}
	models := make(map[string]model, len(rawModels))
	for _, raw := range rawModels {
		if _, err := object(raw, []string{"id", "providerId", "model", "capabilities", "contextWindowTokens", "maxOutputTokens"}, "modelVersion"); err != nil {
			return invalid()
		}
		var m model
		if json.Unmarshal(raw, &m) != nil || !identifier.MatchString(m.ID) || !identifier.MatchString(m.ProviderID) || m.Model == "" || strings.TrimFunc(m.Model, configurationWhitespace) != m.Model || !utf8.ValidString(m.Model) || utf8.RuneCountInString(m.Model) > 256 || !validCapabilities(m.Capabilities) || m.ContextWindowTokens > 2147483647 || m.MaxOutputTokens > 2147483647 || m.MaxOutputTokens >= m.ContextWindowTokens {
			return invalid()
		}
		if m.ModelVersion != nil && !ValidModelVersion(*m.ModelVersion) {
			return invalid()
		}
		if _, exists := models[m.ID]; exists {
			return invalid()
		}
		if _, exists := providers[m.ProviderID]; !exists {
			return invalid()
		}
		sort.Strings(m.Capabilities)
		models[m.ID] = m
	}
	bindings, err := object(fields["bindings"], roleNames)
	if err != nil {
		return invalid()
	}
	c := configuration{revision: int64(revision), selections: make(map[string]Selection, len(roleNames))}
	for _, role := range roleNames {
		var profileID string
		if json.Unmarshal(bindings[role], &profileID) != nil {
			return invalid()
		}
		m, exists := models[profileID]
		if !exists || (role == "agent" && !contains(m.Capabilities, "tools")) || (role == "moderation" && !contains(m.Capabilities, "structured-output")) {
			return invalid()
		}
		p := providers[m.ProviderID]
		version := ""
		if m.ModelVersion != nil {
			version = *m.ModelVersion
		}
		c.selections[role] = cloneSelection(Selection{ConfigurationRevision: int64(revision), Role: role, ProfileID: m.ID, ProviderID: p.ID, Adapter: p.Adapter, BaseURL: p.BaseURL, Model: m.Model, ModelVersion: version, APIKeyEnv: p.APIKeyEnv, Capabilities: m.Capabilities, ContextWindowTokens: int64(m.ContextWindowTokens), MaxOutputTokens: int64(m.MaxOutputTokens)})
	}
	return c, nil
}

// ValidHTTPBaseURL validates a configured AI service address before transport.
func ValidHTTPBaseURL(value string) bool {
	if (!strings.HasPrefix(value, "http://") && !strings.HasPrefix(value, "https://")) || strings.ContainsAny(value, "?#\\") || strings.ContainsFunc(value, func(r rune) bool { return configurationWhitespace(r) || r < 32 || r == 127 }) {
		return false
	}
	u, err := url.Parse(value)
	if err != nil || u.User != nil || u.Host == "" || u.Hostname() == "" || u.Opaque != "" {
		return false
	}
	host := u.Hostname()
	if strings.HasPrefix(u.Host, "[") {
		if !strings.Contains(host, ":") || net.ParseIP(host) == nil {
			return false
		}
	} else {
		if strings.ContainsAny(host, ":[]") || len(host) > 253 {
			return false
		}
		labels := strings.Split(strings.TrimSuffix(host, "."), ".")
		for _, label := range labels {
			if !hostLabel.MatchString(label) {
				return false
			}
		}
		if numericHostLabel.MatchString(labels[len(labels)-1]) {
			address := net.ParseIP(host)
			if address == nil || address.To4() == nil || address.String() != host {
				return false
			}
		}
	}
	if strings.HasSuffix(u.Host, ":") {
		return false
	}
	if port := u.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return false
		}
	}
	return true
}

func configurationWhitespace(r rune) bool { return unicode.IsSpace(r) || r == '\uFEFF' }

func validCapabilities(values []string) bool {
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		if (value != "tools" && value != "structured-output" && value != "vision") || seen[value] {
			return false
		}
		seen[value] = true
	}
	return true
}

func contains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func isRole(role string) bool { return contains(roleNames, role) }
