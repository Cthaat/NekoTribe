package server

import (
	"bytes"
	"encoding/json"
	"golang.org/x/crypto/bcrypt"
	"net/http/httptest"
	"os"
	"testing"
)

type passwordInputCase struct {
	ID, Normalized            string
	Raw, Confirm              interface{}
	ValidNewPassword, Matches bool
}

func TestSharedNewPasswordInputs(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-password-input.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases    []passwordInputCase
		APICases []passwordInputCase `json:"apiCases"`
	}
	if err = json.Unmarshal(raw, &f); err != nil || len(f.Cases) != 19 {
		t.Fatal("invalid fixture", err)
	}
	raw, err = os.ReadFile("../../contracts/scenarios/auth-registration.json")
	if err != nil {
		t.Fatal(err)
	}
	var registration struct {
		Base    map[string]interface{}
		Profile SelfUser
	}
	if err = json.Unmarshal(raw, &registration); err != nil {
		t.Fatal(err)
	}
	codec, _ := fixture(t)
	otpHash, _ := bcrypt.GenerateFromPassword([]byte("123456"), 4)
	for _, c := range append(f.Cases, f.APICases...) {
		t.Run(c.ID, func(t *testing.T) {
			reg := &registrationFixture{memorySessions: store(), otp: true, profile: registration.Profile}
			body := map[string]interface{}{}
			for k, v := range registration.Base {
				body[k] = v
			}
			body["password"] = c.Raw
			body["confirm_password"] = c.Confirm
			encoded, _ := json.Marshal(body)
			req := httptest.NewRequest("POST", "/api/v2/auth/registration", bytes.NewReader(encoded))
			req.Header.Set("Content-Type", "application/json")
			res := httptest.NewRecorder()
			NewHandler(codec, reg, CorsPolicy{}).ServeHTTP(res, req)
			valid := c.ValidNewPassword && c.Matches
			status := 400
			if valid {
				status = 200
			}
			if res.Code != status || reg.inserts != boolInt(valid) {
				t.Fatalf("registration status=%d inserts=%d", res.Code, reg.inserts)
			}
			if valid && !matchesLoginPassword(reg.record.PasswordHash, c.Normalized) {
				t.Fatal("registration did not hash canonical password")
			}
			reset := &resetFixture{memorySessions: store(), otpHash: string(otpHash)}
			encoded, _ = json.Marshal(map[string]interface{}{"email": "fake@example.test", "verification_id": "otp_fixture", "code": "123456", "new_password": c.Raw})
			req = httptest.NewRequest("POST", "/api/v2/auth/password-reset", bytes.NewReader(encoded))
			req.Header.Set("Content-Type", "application/json")
			res = httptest.NewRecorder()
			NewHandlerWithConfig(codec, reset, CorsPolicy{}, RefreshConfig{OTPAttemptLimiter: otpAttemptFixture{}}).ServeHTTP(res, req)
			status = 400
			if c.ValidNewPassword {
				status = 200
			}
			if res.Code != status || reset.marks != boolInt(c.ValidNewPassword) || reset.writes != boolInt(c.ValidNewPassword) {
				t.Fatalf("reset status=%d writes=%d", res.Code, reset.writes)
			}
			if c.ValidNewPassword && !matchesLoginPassword(reset.passwordHash, c.Normalized) {
				t.Fatal("reset did not hash canonical password")
			}
		})
	}
}
func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func TestSharedAccountInputs(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-account-input.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []struct {
			ID, Field, Normalized string
			Raw                   interface{}
			Valid                 bool
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	raw, err = os.ReadFile("../../contracts/scenarios/auth-registration.json")
	if err != nil {
		t.Fatal(err)
	}
	var registration struct {
		Base    map[string]interface{}
		Profile SelfUser
	}
	if err = json.Unmarshal(raw, &registration); err != nil {
		t.Fatal(err)
	}
	codec, _ := fixture(t)
	for _, c := range f.Cases {
		t.Run(c.ID, func(t *testing.T) {
			s := &registrationFixture{memorySessions: store(), otp: true, profile: registration.Profile}
			s.flow = true
			s.otpVerified = true
			s.otpEvent = OTPEvent{Account: registration.Base["email"].(string), ID: "otp_fixture", Kind: "register"}
			if c.Field == "email" {
				s.otpEvent.Account = c.Normalized
			}
			body := map[string]interface{}{}
			for k, v := range registration.Base {
				body[k] = v
			}
			body[c.Field] = c.Raw
			encoded, _ := json.Marshal(body)
			req := httptest.NewRequest("POST", "/api/v2/auth/registration", bytes.NewReader(encoded))
			req.Header.Set("Content-Type", "application/json")
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			expected := 400
			if c.Valid {
				expected = 200
			}
			if res.Code != expected || s.inserts != boolInt(c.Valid) {
				t.Fatalf("status=%d inserts=%d", res.Code, s.inserts)
			}
		})
	}
}

func TestInvalidNewEmailAtRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-account-input.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		EmailCases []struct {
			ID, Normalized string
			Raw            interface{}
			Valid          bool
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, c := range f.EmailCases {
		if c.Valid || c.Normalized == "" {
			continue
		}
		for _, kind := range []string{"register", "change_email", "mutation"} {
			t.Run(c.ID+kind, func(t *testing.T) {
				body := map[string]interface{}{"account": c.Raw, "type": kind}
				method, path := "POST", "/api/v2/auth/otp"
				if kind == "mutation" {
					method, path = "PATCH", "/api/v2/users/me/email"
					body = map[string]interface{}{"new_email": c.Raw, "verification_id": "email_fixture", "code": "123456"}
				}
				encoded, _ := json.Marshal(body)
				req := httptest.NewRequest(method, path, bytes.NewReader(encoded))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
				res := httptest.NewRecorder()
				NewHandler(codec, store(), CorsPolicy{}).ServeHTTP(res, req)
				var out struct{ Message string }
				_ = json.Unmarshal(res.Body.Bytes(), &out)
				if res.Code != 400 || out.Message != "邮箱格式错误" {
					t.Fatalf("status=%d message=%s", res.Code, out.Message)
				}
			})
		}
	}
}

func TestNewPasswordPolicyPreservesLegacyLogin(t *testing.T) {
	s, handler, _ := newLoginFixture(t)
	hash, err := bcrypt.GenerateFromPassword([]byte("x"), 4)
	if err != nil {
		t.Fatal(err)
	}
	s.account.PasswordHash = string(hash)
	res := loginRequest(handler, `{"account":"tester","password":" x "}`)
	if res.Code != 200 || len(s.inserted) != 1 || len(res.Result().Cookies()) == 0 {
		t.Fatalf("legacy short login status=%d sessions=%d", res.Code, len(s.inserted))
	}
}
