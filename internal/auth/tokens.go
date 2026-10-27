package auth

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// OpenTwoFactorSecret reads the AES-256-GCM representation produced by Nuxt.
// All decode/authentication failures use a single redacted error.
func (manager *TokenManager) OpenTwoFactorSecret(encrypted, iv, tag string) (string, error) {
	if manager == nil || len(manager.refreshKey) == 0 {
		return "", ErrInvalidToken
	}
	key := sha256.Sum256(manager.refreshKey)
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return "", ErrInvalidToken
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", ErrInvalidToken
	}
	nonce, err := base64.StdEncoding.DecodeString(iv)
	if err != nil || len(nonce) != gcm.NonceSize() {
		return "", ErrInvalidToken
	}
	data, err := base64.StdEncoding.DecodeString(encrypted)
	if err != nil {
		return "", ErrInvalidToken
	}
	authTag, err := base64.StdEncoding.DecodeString(tag)
	if err != nil || len(authTag) != gcm.Overhead() {
		return "", ErrInvalidToken
	}
	plain, err := gcm.Open(nil, nonce, append(data, authTag...), nil)
	if err != nil {
		return "", ErrInvalidToken
	}
	return string(plain), nil
}

// Token errors deliberately omit the token, key, and parser diagnostic.
var ErrInvalidToken = errors.New("invalid token")
var ErrInvalidClaims = errors.New("invalid claims")
var ErrInvalidTokenConfiguration = errors.New("invalid token configuration")

const maxSafeInteger = 9007199254740991

// TokenManager signs/verifies token encoding only. Database session expiration,
// matching access JTI, refresh hash rotation and revocation are separate checks.
type TokenManager struct {
	accessKey  []byte
	refreshKey []byte
	clock      func() time.Time
}

func NewTokenManager(accessKey, refreshKey []byte, clock func() time.Time) (*TokenManager, error) {
	if len(accessKey) == 0 || len(refreshKey) == 0 || clock == nil {
		return nil, ErrInvalidTokenConfiguration
	}
	return &TokenManager{accessKey: append([]byte(nil), accessKey...), refreshKey: append([]byte(nil), refreshKey...), clock: clock}, nil
}

// Formatting must never expose the private signing keys.
func (manager *TokenManager) String() string   { return "TokenManager" }
func (manager *TokenManager) GoString() string { return "TokenManager" }

func (manager *TokenManager) key(kind Kind) []byte {
	if manager == nil {
		return nil
	}
	switch kind {
	case Access:
		return manager.accessKey
	case Refresh:
		return manager.refreshKey
	default:
		return nil
	}
}

// Verify allows exactly the HMAC family accepted by Nuxt's current JWT library.
// It does not require exp or validate future iat: that compatibility is explicit
// in the common vectors, and never removes the mandatory database session check.
func (manager *TokenManager) Verify(token string, kind Kind) (Claims, error) {
	return manager.verify(token, kind, true)
}

// Nuxt's refresh verifier does not require a jti. The database hash remains
// mandatory for every refresh, including older tokens without that claim.
func (manager *TokenManager) VerifyRefreshForRotation(token string) (Claims, error) {
	return manager.verify(token, Refresh, false)
}

func (manager *TokenManager) verify(token string, kind Kind, requireJTI bool) (Claims, error) {
	key := manager.key(kind)
	if len(key) == 0 || manager.clock == nil {
		return Claims{}, ErrInvalidToken
	}
	parsed, err := jwt.ParseWithClaims(token, jwt.MapClaims{}, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return key, nil
	}, jwt.WithValidMethods([]string{"HS256", "HS384", "HS512"}), jwt.WithJSONNumber(), jwt.WithoutClaimsValidation())
	if err != nil || !parsed.Valid {
		return Claims{}, ErrInvalidToken
	}
	payload, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return Claims{}, ErrInvalidToken
	}
	// NumericDate defaults to whole-second truncation in the JWT library.
	// Compare raw numeric claims to Nuxt's whole-second clock instead so that
	// fractional exp/nbf retain their zero-leeway boundary behavior.
	now := float64(manager.clock().Unix())
	for _, name := range []string{"exp", "nbf"} {
		value, exists := payload[name]
		if !exists {
			continue
		}
		number, ok := value.(json.Number)
		if !ok {
			return Claims{}, ErrInvalidToken
		}
		timestamp, err := number.Float64()
		if err != nil || math.IsNaN(timestamp) || math.IsInf(timestamp, 0) ||
			(name == "exp" && timestamp <= now) || (name == "nbf" && timestamp > now) {
			return Claims{}, ErrInvalidToken
		}
	}
	userID, ok := safeUserID(payload["userId"])
	if !ok {
		return Claims{}, ErrInvalidToken
	}
	name, _ := payload["userName"].(string)
	session, _ := payload["sessionId"].(string)
	jti, _ := payload["jti"].(string)
	tokenType, _ := payload["type"].(string)
	claims := Claims{UserID: userID, UserName: name, SessionID: session, JTI: jti, Kind: Kind(tokenType)}
	if claims.UserID <= 0 || claims.UserID > maxSafeInteger || claims.SessionID == "" || (requireJTI && claims.JTI == "") || claims.Kind != kind {
		return Claims{}, ErrInvalidToken
	}
	return claims, nil
}

// Sign issues the same camelCase claims and default HS256 encoding as Nuxt.
// The caller supplies already allocated session/JTI identities, not user input.
func (manager *TokenManager) Sign(claims Claims, lifetimeSeconds int64) (string, error) {
	key := manager.key(claims.Kind)
	if len(key) == 0 || manager.clock == nil || !validClaims(claims) {
		return "", ErrInvalidClaims
	}
	now := manager.clock().Unix()
	if now < 0 || now > maxSafeInteger || lifetimeSeconds <= 0 || lifetimeSeconds > maxSafeInteger-now {
		return "", ErrInvalidClaims
	}
	payload := jwt.MapClaims{"userId": claims.UserID, "userName": claims.UserName,
		"sessionId": claims.SessionID, "type": string(claims.Kind), "jti": claims.JTI,
		"iat": now, "exp": now + lifetimeSeconds}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, payload).SignedString(key)
	if err != nil {
		return "", ErrInvalidClaims
	}
	return token, nil
}

func validClaims(claims Claims) bool {
	return claims.UserID > 0 && claims.UserID <= maxSafeInteger && claims.SessionID != "" && claims.JTI != "" &&
		(claims.Kind == Access || claims.Kind == Refresh)
}

func safeUserID(value interface{}) (int64, bool) {
	var text string
	switch number := value.(type) {
	case json.Number:
		text = string(number)
	case string:
		text = strings.TrimSpace(number)
	default:
		return 0, false
	}
	number, err := strconv.ParseFloat(text, 64)
	if err != nil || math.IsNaN(number) || math.IsInf(number, 0) || number <= 0 || number > maxSafeInteger || math.Trunc(number) != number {
		return 0, false
	}
	return int64(number), true
}

type Kind string

const (
	Access  Kind = "access"
	Refresh Kind = "refresh"
)

type Claims struct {
	UserID    int64
	UserName  string
	SessionID string
	JTI       string
	Kind      Kind
}
