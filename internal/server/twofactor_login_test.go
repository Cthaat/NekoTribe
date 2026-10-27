package server

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type factorFixture struct {
	*loginFixtureStore
	challenge                       LoginChallenge
	factor                          FactorSecret
	consumed, trusted, recoveryUsed bool
	codes                           []RecoveryCode
}

func (s *factorFixture) UseTrustedDevice(context.Context, int64, string, string, string, string) (bool, error) {
	return s.trusted, nil
}
func (s *factorFixture) CreateLoginChallenge(_ context.Context, c LoginChallenge) error {
	s.challenge = c
	return nil
}
func (s *factorFixture) FindLoginChallenge(_ context.Context, id string) (LoginChallenge, bool, error) {
	return s.challenge, !s.consumed && s.challenge.ID == id, nil
}
func (s *factorFixture) FindFactorSecret(context.Context, int64) (FactorSecret, bool, error) {
	return s.factor, true, nil
}
func (s *factorFixture) FindRecoveryCodes(context.Context, int64) ([]RecoveryCode, error) {
	if s.recoveryUsed {
		return nil, nil
	}
	return s.codes, nil
}
func (s *factorFixture) ConsumeRecoveryCode(context.Context, int64) (bool, error) {
	if s.recoveryUsed {
		return false, nil
	}
	s.recoveryUsed = true
	return true, nil
}
func (s *factorFixture) ConsumeLoginChallenge(_ context.Context, id string) (bool, error) {
	if s.consumed || s.challenge.ID != id {
		return false, nil
	}
	s.consumed = true
	return true, nil
}
func (s *factorFixture) TrustLoginDevice(context.Context, LoginChallenge, time.Time) error {
	s.trusted = true
	return nil
}

func factorSecretForTest(t *testing.T, secret string) FactorSecret {
	t.Helper()
	key := sha256.Sum256([]byte("public-fixture-refresh-key-never-use-in-production-2026"))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, gcm.NonceSize())
	ciphertext := gcm.Seal(nil, nonce, []byte(secret), nil)
	n := len(ciphertext) - gcm.Overhead()
	return FactorSecret{Encrypted: base64.StdEncoding.EncodeToString(ciphertext[:n]), IV: base64.StdEncoding.EncodeToString(nonce), Tag: base64.StdEncoding.EncodeToString(ciphertext[n:]), Enabled: true}
}
func challengeFixture(t *testing.T) (*factorFixture, http.Handler) {
	t.Helper()
	base, _, codec := newLoginFixture(t)
	base.twoFactor = true
	factor := &factorFixture{loginFixtureStore: base, factor: factorSecretForTest(t, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")}
	h := NewHandlerWithConfig(codec, factor, CorsPolicy{}, RefreshConfig{AccessSeconds: 900, RefreshSeconds: 3600, clock: func() time.Time { return time.Unix(59, 0) }})
	return factor, h
}
func factorRequest(h http.Handler, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/api/v2/auth/two-factor/challenges", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func TestTotpMatchesRFCVector(t *testing.T) {
	if matched, err := verifyTOTP("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "287082", time.Unix(59, 0)); err != nil || !matched {
		t.Fatal("RFC 6238 SHA1 vector mismatch")
	}
	if matched, err := verifyTOTP("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "287083", time.Unix(59, 0)); err != nil || matched {
		t.Fatal("accepted wrong code")
	}
}

func TestTwoFactorCodeUsesJavascriptWhitespace(t *testing.T) {
	for _, tc := range []struct {
		name, code string
		status     int
	}{
		{"FEFF removed", `\ufeff287\ufeff082\ufeff`, 200},
		{"U+0085 retained", `\u0085287082`, 401},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, h := challengeFixture(t)
			if loginRequest(h, `{"account":"tester","password":"synthetic-password"}`).Code != 200 {
				t.Fatal("challenge not created")
			}
			response := factorRequest(h, fmt.Sprintf(`{"challenge_id":%q,"code":"%s"}`, s.challenge.ID, tc.code))
			if response.Code != tc.status {
				t.Fatalf("status=%d", response.Code)
			}
			if tc.status != 200 && (s.consumed || len(s.inserted) != 0 || len(response.Result().Cookies()) != 0) {
				t.Fatal("failed code authorized session")
			}
		})
	}
}

func TestTwoFactorInvalidSecretDistinguishesTotpAndRecovery(t *testing.T) {
	s, h := challengeFixture(t)
	s.factor = factorSecretForTest(t, "INVALID!")
	if loginRequest(h, `{"account":"tester","password":"synthetic-password"}`).Code != 200 {
		t.Fatal("challenge not created")
	}
	response := factorRequest(h, fmt.Sprintf(`{"challenge_id":%q,"code":"123456"}`, s.challenge.ID))
	if response.Code != 400 || !strings.Contains(response.Body.String(), "双因素密钥格式错误") || s.consumed || len(response.Result().Cookies()) != 0 {
		t.Fatal("invalid secret was not safely rejected")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte("ABCDE12345"), 4)
	if err != nil {
		t.Fatal(err)
	}
	s.codes = []RecoveryCode{{ID: 1, Hash: string(hash)}}
	response = factorRequest(h, fmt.Sprintf(`{"challenge_id":%q,"code":"abcde-12345"}`, s.challenge.ID))
	if response.Code != 200 || !s.recoveryUsed || !s.consumed {
		t.Fatal("non-six-digit recovery should not decode the TOTP secret")
	}
}
func TestTwoFactorChallengeCompletionAndReplay(t *testing.T) {
	s, h := challengeFixture(t)
	r := httptest.NewRequest("POST", "/api/v2/auth/tokens", strings.NewReader(`{"account":"tester","password":"synthetic-password","remember_me":true}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Device-Fingerprint", "fixture-device")
	r.Header.Set("X-Device-Info", "test device")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || len(w.Result().Cookies()) != 0 || s.challenge.ID == "" || len(s.inserted) != 0 {
		t.Fatal("challenge did not precede session")
	}
	body := fmt.Sprintf(`{"challenge_id":%q,"code":"287082"}`, s.challenge.ID)
	bad := factorRequest(h, fmt.Sprintf(`{"challenge_id":%q,"code":"287083"}`, s.challenge.ID))
	if bad.Code != 401 || s.consumed {
		t.Fatal("invalid factor consumed challenge")
	}
	ok := factorRequest(h, body)
	if ok.Code != 200 || len(ok.Result().Cookies()) != 2 || !s.consumed || !s.trusted || len(s.inserted) != 1 {
		t.Fatalf("completion status %d", ok.Code)
	}
	var payload struct {
		Message string `json:"message"`
		Data    struct {
			TwoFactorRequired bool `json:"two_factor_required"`
		} `json:"data"`
	}
	if json.Unmarshal(ok.Body.Bytes(), &payload) != nil || payload.Message != "login success" || payload.Data.TwoFactorRequired {
		t.Fatal("bad login response")
	}
	replay := factorRequest(h, body)
	if replay.Code != 401 || len(s.inserted) != 1 {
		t.Fatal("replayed challenge")
	}
}
func TestTwoFactorRecoveryCodeConsumed(t *testing.T) {
	s, h := challengeFixture(t)
	hash, err := bcrypt.GenerateFromPassword([]byte("ABCDE12345"), 4)
	if err != nil {
		t.Fatal(err)
	}
	s.codes = []RecoveryCode{{ID: 1, Hash: string(hash)}}
	begin := loginRequest(h, `{"account":"tester","password":"synthetic-password"}`)
	if begin.Code != 200 {
		t.Fatal(begin.Code)
	}
	done := factorRequest(h, fmt.Sprintf(`{"challenge_id":%q,"code":"abcde-12345"}`, s.challenge.ID))
	if done.Code != 200 || !s.recoveryUsed || !s.consumed {
		t.Fatalf("recovery code not consumed: %d", done.Code)
	}
}

func TestTwoFactorPathIDTakesPrecedence(t *testing.T) {
	s, h := challengeFixture(t)
	if loginRequest(h, `{"account":"tester","password":"synthetic-password"}`).Code != 200 {
		t.Fatal("challenge not created")
	}
	r := httptest.NewRequest("POST", "/api/v2/auth/two-factor/challenges/"+s.challenge.ID, strings.NewReader(`{"challenge_id":"wrong","code":"287082"}`))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || !s.consumed || len(s.inserted) != 1 {
		t.Fatal("path id did not take precedence")
	}
}

func TestTwoFactorTrustedDeviceAndBadCiphertext(t *testing.T) {
	s, h := challengeFixture(t)
	s.trusted = true
	r := httptest.NewRequest("POST", "/api/v2/auth/tokens", strings.NewReader(`{"account":"tester","password":"synthetic-password"}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Device-Fingerprint", "fixture-device")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || len(w.Result().Cookies()) != 2 || len(s.inserted) != 1 || s.challenge.ID != "" {
		t.Fatal("trusted device did not issue session")
	}
	s, h = challengeFixture(t)
	if loginRequest(h, `{"account":"tester","password":"synthetic-password"}`).Code != 200 {
		t.Fatal("challenge not created")
	}
	s.factor.Tag = "invalid-public-tag"
	w = factorRequest(h, fmt.Sprintf(`{"challenge_id":%q,"code":"287082"}`, s.challenge.ID))
	if w.Code != 500 || s.consumed || len(w.Result().Cookies()) != 0 || strings.Contains(w.Body.String(), "invalid-public-tag") {
		t.Fatal("ciphertext failure leaked or authorized")
	}
}
