package server

import (
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"math/big"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/protocol/webauthncbor"
	"github.com/go-webauthn/webauthn/protocol/webauthncose"
	"github.com/go-webauthn/webauthn/webauthn"
)

type passkeyPolicy struct {
	TTLSeconds           int               `json:"ttlSeconds"`
	TimeoutMS            int               `json:"timeoutMs"`
	MaxPayloadBytes      int               `json:"maxPayloadBytes"`
	MaxLabelChars        int               `json:"maxLabelChars"`
	Algorithm            int64             `json:"algorithm"`
	ChallengeIDBytes     int               `json:"challengeIdBytes"`
	MaxCredentialIDBytes int               `json:"maxCredentialIdBytes"`
	UserHandleBytes      int               `json:"userHandleBytes"`
	PasswordHashPattern  string            `json:"passwordHashPattern"`
	SQL                  map[string]string `json:"sql"`
}

var passkeyAuth = func() passkeyPolicy {
	var p passkeyPolicy
	if json.Unmarshal(contracts.PasskeyAuth, &p) != nil || p.TTLSeconds < 1 || p.TimeoutMS < 1 ||
		p.MaxPayloadBytes < 1 || p.MaxLabelChars < 1 || p.Algorithm != -7 ||
		p.ChallengeIDBytes != 32 || p.MaxCredentialIDBytes < 1 || p.UserHandleBytes != 16 || p.PasswordHashPattern == "" {
		panic("invalid passkey contract")
	}
	return p
}()

var (
	errPasskeyUnavailable = errors.New("passkey unavailable")
	errPasskeyInvalid     = errors.New("passkey request invalid")
	errPasskeyProof       = errors.New("passkey proof or challenge invalid")
	errPasskeyOwner       = errors.New("passkey account unavailable")
	errPasskeyMissing     = errors.New("passkey not found")
	errPasskeyConflict    = errors.New("passkey credential already registered")
	errPasskeyLast        = errors.New("must retain a login method")
	passkeyPasswordHash   = regexp.MustCompile(passkeyAuth.PasswordHashPattern)
	passkeyDomainLabel    = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
)

const (
	passkeyRegister = "register"
	passkeyLogin    = "login"
	passkeyIssuer   = "go"
	passkeyStale    = "Passkey 验证失败，请重试"
)

type passkeyEngine struct{ web *webauthn.WebAuthn }

func configuredPasskeys(rpID, origins string) *passkeyEngine {
	rpID = strings.ToLower(strings.TrimSpace(rpID))
	if protocol.ValidateRPID(rpID) != nil {
		return nil
	}
	for _, label := range strings.Split(rpID, ".") {
		if !passkeyDomainLabel.MatchString(label) {
			return nil
		}
	}
	var list []string
	for _, value := range strings.Split(origins, ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		origin, ok := configuredPasskeyOrigin(value)
		if !ok {
			return nil
		}
		if !slices.Contains(list, origin) {
			list = append(list, origin)
		}
	}
	timeout := time.Duration(passkeyAuth.TimeoutMS) * time.Millisecond
	engine, err := webauthn.New(&webauthn.Config{
		RPID: rpID, RPDisplayName: "NekoTribe", RPOrigins: list,
		AttestationPreference:  protocol.PreferNoAttestation,
		AuthenticatorSelection: protocol.AuthenticatorSelection{UserVerification: protocol.VerificationRequired},
		Timeouts: webauthn.TimeoutsConfig{
			Login: webauthn.TimeoutConfig{Timeout: timeout}, Registration: webauthn.TimeoutConfig{Timeout: timeout},
		},
	})
	if err != nil {
		return nil
	}
	return &passkeyEngine{web: engine}
}

func configuredPasskeyOrigin(value string) (string, bool) {
	if hash, ok := strings.CutPrefix(value, "android:apk-key-hash:"); ok {
		_, valid := passkeyDecode(hash, 32, 32)
		return value, valid
	}
	u, err := url.Parse(value)
	if err != nil || u.Hostname() == "" || u.User != nil || u.Opaque != "" || u.RawQuery != "" || u.ForceQuery ||
		u.Path != "" || strings.Contains(value, "#") || strings.HasSuffix(u.Host, ":") {
		return "", false
	}
	host := strings.ToLower(u.Hostname())
	if u.Scheme != "https" && (u.Scheme != "http" || host != "localhost") {
		return "", false
	}
	if strings.ContainsAny(host, "*% \\^") {
		return "", false
	}
	port := u.Port()
	if port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 || strconv.Itoa(n) != port {
			return "", false
		}
	}
	u.Host = strings.ToLower(u.Host)
	if u.Scheme == "https" && port == "443" || u.Scheme == "http" && port == "80" {
		u.Host = strings.TrimSuffix(u.Host, ":"+port)
	}
	origin := u.String()
	return origin, origin == value
}

func passkeyEncode(value []byte) string { return base64.RawURLEncoding.EncodeToString(value) }

func passkeyDecode(encoded string, minBytes, maxBytes int) ([]byte, bool) {
	if len(encoded) > base64.RawURLEncoding.EncodedLen(maxBytes) {
		return nil, false
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	return raw, err == nil && len(raw) >= minBytes && len(raw) <= maxBytes && passkeyEncode(raw) == encoded
}

func passkeyUserHandle(user int64) []byte {
	handle := make([]byte, passkeyAuth.UserHandleBytes)
	binary.BigEndian.PutUint64(handle[8:], uint64(user))
	return handle
}

func passkeyHandleUser(handle []byte) (int64, bool) {
	if len(handle) != passkeyAuth.UserHandleBytes || binary.BigEndian.Uint64(handle[:8]) != 0 {
		return 0, false
	}
	user := binary.BigEndian.Uint64(handle[8:])
	return int64(user), user > 0 && user <= uint64(maxSocketID)
}

func newPasskeyID() (string, error) {
	raw := make([]byte, passkeyAuth.ChallengeIDBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", errSessionStore
	}
	return passkeyEncode(raw), nil
}

type passkeyOwner struct {
	LoginAccount
	display string
	keys    []webauthn.Credential
}

func (u passkeyOwner) WebAuthnID() []byte                         { return passkeyUserHandle(u.UserID) }
func (u passkeyOwner) WebAuthnName() string                       { return u.Username }
func (u passkeyOwner) WebAuthnCredentials() []webauthn.Credential { return u.keys }
func (u passkeyOwner) WebAuthnDisplayName() string {
	if u.display == "" {
		return u.Username
	}
	return u.display
}

type passkeyCredentialInfo struct {
	ID       string  `json:"credential_id"`
	Label    string  `json:"label"`
	Created  string  `json:"created_at"`
	LastUsed *string `json:"last_used_at"`
}

type passkeyCredential struct {
	passkeyCredentialInfo
	owner          int64
	x, y           string
	count          uint32
	eligible, back bool
}

type passkeyUse struct {
	count uint32
	back  bool
}

func parsePasskeyLabel(raw json.RawMessage) (string, error) {
	if raw == nil {
		return "Passkey", nil
	}
	var text *string
	if json.Unmarshal(raw, &text) != nil || text == nil {
		return "", errPasskeyInvalid
	}
	label := strings.TrimFunc(*text, jsTrimSpace)
	if utf8.RuneCountInString(label) > passkeyAuth.MaxLabelChars || strings.ContainsRune(label, 0) {
		return "", errPasskeyInvalid
	}
	if label == "" {
		return "Passkey", nil
	}
	return label, nil
}

func passkeyP256(x, y []byte) bool {
	return len(x) == 32 && len(y) == 32 &&
		elliptic.P256().IsOnCurve(new(big.Int).SetBytes(x), new(big.Int).SetBytes(y))
}

func passkeyCoordinates(credential *webauthn.Credential) (string, string, bool) {
	key, err := webauthncose.ParsePublicKey(credential.PublicKey)
	point, ok := key.(webauthncose.EC2PublicKeyData)
	if err != nil || !ok || point.Algorithm != passkeyAuth.Algorithm || point.Curve != 1 || !passkeyP256(point.XCoord, point.YCoord) {
		return "", "", false
	}
	return passkeyEncode(point.XCoord), passkeyEncode(point.YCoord), true
}

func (c passkeyCredential) libraryCredential() (webauthn.Credential, error) {
	id, idOK := passkeyDecode(c.ID, 1, passkeyAuth.MaxCredentialIDBytes)
	x, xOK := passkeyDecode(c.x, 32, 32)
	y, yOK := passkeyDecode(c.y, 32, 32)
	if !idOK || !xOK || !yOK || !passkeyP256(x, y) || c.back && !c.eligible {
		return webauthn.Credential{}, errPasskeyProof
	}
	key, err := webauthncbor.Marshal(webauthncose.EC2PublicKeyData{
		PublicKeyData: webauthncose.PublicKeyData{KeyType: 2, Algorithm: passkeyAuth.Algorithm},
		Curve:         1, XCoord: x, YCoord: y,
	})
	if err != nil {
		return webauthn.Credential{}, errSessionStore
	}
	flags := protocol.FlagUserPresent | protocol.FlagUserVerified
	if c.eligible {
		flags |= protocol.FlagBackupEligible
	}
	if c.back {
		flags |= protocol.FlagBackupState
	}
	return webauthn.Credential{ID: id, PublicKey: key,
		Flags: webauthn.NewCredentialFlags(flags), Authenticator: webauthn.Authenticator{SignCount: c.count}}, nil
}

func (e *passkeyEngine) decodeState(challenge, raw string) (webauthn.SessionData, error) {
	var session webauthn.SessionData
	if json.Unmarshal([]byte(raw), &session) != nil || session.Challenge != challenge || challenge == "" ||
		session.RelyingPartyID != e.web.Config.RPID || session.UserVerification != protocol.VerificationRequired ||
		session.Mediation == protocol.MediationConditional {
		return webauthn.SessionData{}, errPasskeyProof
	}
	return session, nil
}

func (e *passkeyEngine) register(owner int64, session webauthn.SessionData, raw []byte, label string) (passkeyCredential, error) {
	parsed, err := protocol.ParseCredentialCreationResponseBytes(raw)
	if err != nil || !slices.Contains(e.web.Config.RPOrigins, parsed.Response.CollectedClientData.Origin) ||
		parsed.ID != passkeyEncode(parsed.RawID) || len(parsed.RawID) < 1 || len(parsed.RawID) > passkeyAuth.MaxCredentialIDBytes {
		return passkeyCredential{}, errPasskeyProof
	}
	if props := parsed.ClientExtensionResults.CredProps; props != nil && props.RK != nil && !*props.RK {
		return passkeyCredential{}, errPasskeyProof
	}
	verified, err := e.web.CreateCredential(passkeyOwner{LoginAccount: LoginAccount{UserID: owner}}, session, parsed)
	if err != nil {
		return passkeyCredential{}, errPasskeyProof
	}
	x, y, ok := passkeyCoordinates(verified)
	if !ok {
		return passkeyCredential{}, errPasskeyProof
	}
	return passkeyCredential{passkeyCredentialInfo: passkeyCredentialInfo{ID: passkeyEncode(verified.ID), Label: label},
		owner: owner, x: x, y: y, count: verified.Authenticator.SignCount, eligible: verified.Flags.BackupEligible, back: verified.Flags.BackupState}, nil
}

func (e *passkeyEngine) assert(session webauthn.SessionData, raw []byte) (int64, string, func(passkeyCredential) (passkeyUse, error), error) {
	parsed, err := protocol.ParseCredentialRequestResponseBytes(raw)
	if err != nil || !slices.Contains(e.web.Config.RPOrigins, parsed.Response.CollectedClientData.Origin) ||
		parsed.ID != passkeyEncode(parsed.RawID) || len(parsed.RawID) < 1 || len(parsed.RawID) > passkeyAuth.MaxCredentialIDBytes {
		return 0, "", nil, errPasskeyProof
	}
	var wire struct {
		Response struct {
			UserHandle string `json:"userHandle"`
		} `json:"response"`
	}
	if json.Unmarshal(raw, &wire) != nil || wire.Response.UserHandle != passkeyEncode(parsed.Response.UserHandle) {
		return 0, "", nil, errPasskeyProof
	}
	owner, ok := passkeyHandleUser(parsed.Response.UserHandle)
	if !ok {
		return 0, "", nil, errPasskeyProof
	}
	verify := func(stored passkeyCredential) (passkeyUse, error) {
		credential, err := stored.libraryCredential()
		if err != nil {
			return passkeyUse{}, err
		}
		_, verified, err := e.web.ValidatePasskeyLogin(func(rawID, userHandle []byte) (webauthn.User, error) {
			if stored.owner != owner || !slices.Equal(rawID, credential.ID) || !slices.Equal(userHandle, passkeyUserHandle(stored.owner)) {
				return nil, errPasskeyProof
			}
			return passkeyOwner{LoginAccount: LoginAccount{UserID: stored.owner}, keys: []webauthn.Credential{credential}}, nil
		}, session, parsed)
		count := parsed.Response.AuthenticatorData.Counter
		if err != nil || verified.Authenticator.CloneWarning || (stored.count != 0 || count != 0) && count <= stored.count {
			return passkeyUse{}, errPasskeyProof
		}
		return passkeyUse{count: count, back: verified.Flags.BackupState}, nil
	}
	return owner, parsed.ID, verify, nil
}
