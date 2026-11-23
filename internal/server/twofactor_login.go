package server

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type LoginChallenge struct {
	ID                                            string
	UserID                                        int64
	Username                                      string
	Remember                                      bool
	DeviceInfo, Fingerprint, IPAddress, UserAgent string
	ExpiresAt                                     time.Time
	verifiedPasswordHash                          string
}
type FactorSecret struct {
	Encrypted, IV, Tag string
	Enabled            bool
}
type RecoveryCode struct {
	ID   int64
	Hash string
}
type TwoFactorRepository interface {
	CreateLoginChallenge(context.Context, LoginChallenge) error
	FindLoginChallenge(context.Context, string) (LoginChallenge, bool, error)
	FindFactorSecret(context.Context, int64) (FactorSecret, bool, error)
	FindRecoveryCodes(context.Context, int64) ([]RecoveryCode, error)
}

type factorCompletion struct {
	challenge      LoginChallenge
	verifiedSecret FactorSecret
	recoveryCodeID *int64
	trustedKey     string
	trustedExpiry  time.Time
}

const factorChallengeExpired = "双因素验证已过期，请重新登录"
const trustedDeviceCookie = "nekotribe_trusted_device"
const trustedDeviceLifetime = 30 * 24 * time.Hour

func trustedDeviceKey(r *http.Request) string {
	cookie, err := r.Cookie(trustedDeviceCookie)
	if err != nil || len(cookie.Value) != 68 || !strings.HasPrefix(cookie.Value, "td1_") {
		return ""
	}
	value := cookie.Value[4:]
	if _, err := hex.DecodeString(value); err != nil || value != strings.ToLower(value) {
		return ""
	}
	return "td1_" + refreshHash(cookie.Value)
}

func truncateDevice(value string) string {
	r := []rune(value)
	if len(r) > 200 {
		return string(r[:200])
	}
	return value
}

func beginTwoFactor(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, store LoginRepository, user LoginAccount, account, staleMessage string, remember bool, config RefreshConfig, success loginSuccessResponse) {
	factor, ok := store.(TwoFactorRepository)
	if !ok {
		respond(w, 503, 50301, "双因素登录暂不可用", nil)
		return
	}
	fingerprint := truncateDevice(headerDefault(r, "X-Device-Fingerprint"))
	info := truncateDevice(headerDefault(r, "X-Device-Info"))
	ip := requestIP(r, config.TrustProxy)
	agent := headerDefault(r, "User-Agent")
	if key := trustedDeviceKey(r); key != "" &&
		issueLogin(w, r, codec, store, user, staleMessage, config, loginSessionOptions{requiredKey: key, success: success}) {
		return
	}
	// Nuxt rechecks readiness before creating a challenge, after the trusted
	// device lookup. Never assume an earlier successful check is still current.
	if err := store.CheckTwoFactorSchema(r.Context()); err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	id, err := randomUUID()
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	challenge := LoginChallenge{ID: "2fa_" + id, UserID: user.UserID, Username: user.Username, Remember: remember, DeviceInfo: info, Fingerprint: fingerprint, IPAddress: ip, UserAgent: agent, ExpiresAt: config.clock().UTC().Truncate(time.Millisecond).Add(5 * time.Minute)}
	challenge.verifiedPasswordHash = user.PasswordHash
	if err = factor.CreateLoginChallenge(r.Context(), challenge); err != nil {
		if errors.Is(err, errLoginCredentialsChanged) {
			respond(w, 401, 40101, staleMessage, nil)
			return
		}
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	success.send(w, "two factor required", map[string]interface{}{"two_factor_required": true, "challenge_id": challenge.ID, "account": account, "expires_at": challenge.ExpiresAt.Format("2006-01-02T15:04:05.000Z")})
}

func completeTwoFactor(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, pathID string) {
	body, valid := readLoginBody(r)
	if !valid {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	challengeID := loginString(body["challenge_id"])
	if pathID != "" {
		challengeID = pathID
	}
	code := loginString(body["code"])
	if challengeID == "" {
		respond(w, 400, 40001, "challenge_id 不能为空", nil)
		return
	}
	if code == "" {
		respond(w, 400, 40001, "code 不能为空", nil)
		return
	}
	store, ok := repository.(LoginRepository)
	if !ok {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	factor, ok := repository.(TwoFactorRepository)
	if !ok {
		respond(w, 503, 50301, "双因素登录暂不可用", nil)
		return
	}
	if err := store.CheckTwoFactorSchema(r.Context()); err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	challenge, found, err := factor.FindLoginChallenge(r.Context(), challengeID)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	storedFingerprint := challenge.Fingerprint
	if storedFingerprint == "" {
		storedFingerprint = "unknown"
	}
	if !found || storedFingerprint != truncateDevice(headerDefault(r, "X-Device-Fingerprint")) {
		respond(w, 401, 40101, factorChallengeExpired, nil)
		return
	}
	// Nuxt rechecks immediately before loading the 2FA secret. A previous
	// readiness result is not cached and cannot authorize a later schema state.
	if err := store.CheckTwoFactorSchema(r.Context()); err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	secret, found, err := factor.FindFactorSecret(r.Context(), challenge.UserID)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found || !secret.Enabled {
		respond(w, 422, 42201, "双因素认证尚未启用", nil)
		return
	}
	plain, err := codec.OpenTwoFactorSecret(secret.Encrypted, secret.IV, secret.Tag)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	normalized := normalizeFactorCode(code)
	matched, err := verifyTOTP(plain, normalized, config.clock())
	if err != nil {
		respond(w, 400, 40001, "双因素密钥格式错误", nil)
		return
	}
	completion := &factorCompletion{challenge: challenge, verifiedSecret: secret}
	if !matched && !isSixDigits(normalized) {
		codes, err := factor.FindRecoveryCodes(r.Context(), challenge.UserID)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		for _, candidate := range codes {
			if matchesLoginPassword(candidate.Hash, normalized) {
				completion.recoveryCodeID = &candidate.ID
				matched = true
				break
			}
		}
	}
	if !matched {
		respond(w, 401, 40101, "双因素验证码错误", nil)
		return
	}
	proof := ""
	if challenge.Remember && challenge.Fingerprint != "" && challenge.Fingerprint != "unknown" {
		var bytes [32]byte
		if _, err = rand.Read(bytes[:]); err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		proof = "td1_" + hex.EncodeToString(bytes[:])
		completion.trustedKey = "td1_" + refreshHash(proof)
		completion.trustedExpiry = config.clock().UTC().Add(trustedDeviceLifetime)
	}
	user := LoginAccount{UserID: challenge.UserID, Username: challenge.Username, PasswordHash: challenge.verifiedPasswordHash}
	issueLogin(w, r, codec, store, user, factorChallengeExpired, config,
		loginSessionOptions{issuedProof: proof, completion: completion})
}

func normalizeFactorCode(code string) string {
	return strings.ToUpper(strings.Map(func(r rune) rune {
		if jsTrimSpace(r) || r == '-' {
			return -1
		}
		return r
	}, code))
}
func isSixDigits(code string) bool {
	if len(code) != 6 {
		return false
	}
	for _, c := range code {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
func verifyTOTP(secret, code string, now time.Time) (bool, error) {
	if !isSixDigits(code) {
		return false, nil
	}
	clean := strings.ToUpper(strings.Map(func(r rune) rune {
		if jsTrimSpace(r) {
			return -1
		}
		return r
	}, strings.TrimRight(secret, "=")))
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	var key []byte
	var accumulator uint32
	bits := 0
	for _, r := range clean {
		index := strings.IndexRune(alphabet, r)
		if index < 0 {
			return false, errors.New("invalid factor secret")
		}
		accumulator = (accumulator << 5) | uint32(index)
		bits += 5
		if bits >= 8 {
			key = append(key, byte(accumulator>>uint(bits-8)))
			bits -= 8
		}
	}
	for offset := int64(-1); offset <= 1; offset++ {
		step := now.Unix()/30 + offset
		if step < 0 {
			step = 0
		}
		var counter [8]byte
		binary.BigEndian.PutUint64(counter[:], uint64(step))
		mac := hmac.New(sha1.New, key)
		_, _ = mac.Write(counter[:])
		sum := mac.Sum(nil)
		i := sum[len(sum)-1] & 15
		value := binary.BigEndian.Uint32(sum[i:i+4]) & 0x7fffffff
		expected := fmt.Sprintf("%06d", value%1000000)
		if subtle.ConstantTimeCompare([]byte(expected), []byte(code)) == 1 {
			return true, nil
		}
	}
	return false, nil
}
