package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

type registrationFixture struct {
	*memorySessions
	profile        SelfUser
	otp, duplicate bool
	fault          string
	inserts        int
	record         RegistrationRecord
	profileMissing bool
	flow           bool
	otpEvent       OTPEvent
	otpVerified    bool
}

func (s *registrationFixture) VerifiedRegistrationOTP(_ context.Context, email, id string) (bool, error) {
	if s.fault == "otp" {
		return false, errors.New("registration-internal-fixture")
	}
	if s.flow {
		return s.otpVerified && s.otpEvent.Account == email && s.otpEvent.ID == id && s.otpEvent.Kind == "register", nil
	}
	return s.otp && email == "new@example.test" && id == "otp_fixture", nil
}
func (s *registrationFixture) NextOTPID(context.Context) (int64, error) { return 321, nil }
func (s *registrationFixture) InsertOTP(_ context.Context, e OTPEvent) error {
	s.otpEvent = e
	return nil
}
func (s *registrationFixture) FindOTP(_ context.Context, email, kind, id string) (string, bool, error) {
	return s.otpEvent.Hash, s.otpEvent.ID == id && s.otpEvent.Account == email && s.otpEvent.Kind == kind, nil
}
func (s *registrationFixture) MarkOTPVerified(context.Context, string) error {
	s.otpVerified = true
	return nil
}
func (s *registrationFixture) OTPVerifiedAt(context.Context, string) (*time.Time, error) {
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	return &at, nil
}

type registrationFlowMailer struct{ code string }

func (m *registrationFlowMailer) SendOTP(_ context.Context, _, code string) error {
	m.code = code
	return nil
}
func (s *registrationFixture) RegistrationExists(context.Context, string, string) (bool, error) {
	if s.fault == "duplicate" {
		return false, errors.New("registration-internal-fixture")
	}
	return s.duplicate, nil
}
func (s *registrationFixture) NextRegistrationID(context.Context) (int64, error) {
	if s.fault == "sequence" {
		return 0, errors.New("registration-internal-fixture")
	}
	return 123, nil
}
func (s *registrationFixture) InsertRegistration(_ context.Context, r RegistrationRecord, _ string) error {
	if s.fault == "consumed" {
		return errRegistrationOTPMissing
	}
	if s.fault == "insert" {
		return errors.New("registration-internal-fixture")
	}
	s.inserts++
	s.record = r
	return nil
}
func (s *registrationFixture) SelfProfile(context.Context, int64) (SelfUser, bool, error) {
	if s.fault == "profile" {
		return SelfUser{}, false, errors.New("registration-internal-fixture")
	}
	if s.profileMissing {
		return SelfUser{}, false, nil
	}
	return s.profile, true, nil
}
func TestSharedRegistration(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-registration.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Base        map[string]interface{}
		Profile     SelfUser
		HashInterop struct {
			Password, WrongPassword string
			Hashes                  []struct{ Producer, Hash string }
		} `json:"hashInterop"`
		Cases []struct {
			ID, OTP, Fault  string
			Patch           map[string]interface{}
			Duplicate       bool
			ProfileMissing  bool   `json:"profile_missing"`
			ExpectedPhone   string `json:"expected_phone"`
			Status, Inserts int
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) != 30 {
		t.Fatalf("expected 30 registration cases, got %d", len(f.Cases))
	}
	codec, _ := fixture(t)
	if len(f.HashInterop.Hashes) != 2 {
		t.Fatal("missing synthetic interoperability samples")
	}
	for _, sample := range f.HashInterop.Hashes {
		if !matchesLoginPassword(sample.Hash, f.HashInterop.Password) || matchesLoginPassword(sample.Hash, f.HashInterop.WrongPassword) {
			t.Fatal("bcrypt interoperability failed for", sample.Producer)
		}
	}
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			body := make(map[string]interface{})
			for k, v := range f.Base {
				body[k] = v
			}
			for k, v := range tc.Patch {
				body[k] = v
			}
			data, _ := json.Marshal(body)
			store := &registrationFixture{memorySessions: store(), profile: f.Profile, otp: tc.OTP == "", duplicate: tc.Duplicate, fault: tc.Fault, profileMissing: tc.ProfileMissing}
			h := NewHandler(codec, store, CorsPolicy{})
			req := httptest.NewRequest("POST", "/api/v2/auth/registration", bytes.NewReader(data))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Cookie", "access_token=expired")
			response := httptest.NewRecorder()
			h.ServeHTTP(response, req)
			if response.Code != tc.Status || store.inserts != tc.Inserts || len(response.Result().Cookies()) != 0 || strings.Contains(response.Body.String(), "registration-internal-fixture") || strings.Contains(response.Body.String(), "synthetic-password") {
				t.Fatalf("status=%d inserts=%d", response.Code, store.inserts)
			}
			if tc.Status == 200 {
				var out struct {
					Data struct {
						User SelfUser `json:"user"`
					} `json:"data"`
				}
				if err := json.Unmarshal(response.Body.Bytes(), &out); err != nil || !reflect.DeepEqual(out.Data.User, f.Profile) || !matchesLoginPassword(store.record.PasswordHash, body["password"].(string)) {
					t.Fatal("bad profile or password hash", err)
				}
				if store.record.UserID != 123 {
					t.Fatal("wrong user id")
				}
				if tc.ExpectedPhone != "" && store.record.Phone != tc.ExpectedPhone {
					t.Fatalf("phone conversion mismatch: %s", tc.ID)
				}
				if tc.ID == "REG-19" && (store.record.Bio != "  retained  " || store.record.Location != "false" || store.record.Phone != "123") {
					t.Fatal("optional fields changed")
				}
			}
		})
	}
}

func TestRegistrationRejectsUnsafeStorageConfigAfterInsert(t *testing.T) {
	codec, _ := fixture(t)
	store := &registrationFixture{memorySessions: store(), otp: true, profile: SelfUser{UserID: 123, AvatarURL: "/storage/default-avatar.png"}}
	lookup := func(k string) (string, bool) {
		if k == "BASE_URL" {
			return "https://user:synthetic-secret@example.test", true
		}
		return "", false
	}
	h := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{Storage: storageURLConfig(lookup)})
	body := `{"email":"new@example.test","username":"newuser","password":"synthetic-password","confirm_password":"synthetic-password","display_name":"New User","verification_id":"otp_fixture","agree_to_terms":true}`
	req := httptest.NewRequest("POST", "/api/v2/auth/registration", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()
	h.ServeHTTP(res, req)
	if res.Code != 500 || store.inserts != 1 || strings.Contains(res.Body.String(), "synthetic-secret") || len(res.Result().Cookies()) != 0 {
		t.Fatal("unsafe storage config was not handled safely")
	}
}

func TestOTPToRegistrationFlow(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/auth-registration.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Base    map[string]interface{}
		Profile SelfUser
	}
	if err = json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	codec, _ := fixture(t)
	store := &registrationFixture{memorySessions: store(), profile: f.Profile, flow: true}
	mailer := &registrationFlowMailer{}
	h := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{clock: func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) }, OTPAttemptLimiter: otpAttemptFixture{}, otpMailer: mailer, OTPSendLimiter: otpLimitFixture{}})
	post := func(path string, body interface{}) *httptest.ResponseRecorder {
		data, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", path, bytes.NewReader(data))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	created := post("/api/v2/auth/otp", map[string]string{"account": "new@example.test", "type": "register"})
	if created.Code != 200 || mailer.code == "" {
		t.Fatal("OTP creation failed")
	}
	var c struct {
		Data struct {
			ID string `json:"verification_id"`
		}
	}
	if json.Unmarshal(created.Body.Bytes(), &c) != nil {
		t.Fatal("invalid creation response")
	}
	f.Base["verification_id"] = c.Data.ID
	if post("/api/v2/auth/registration", f.Base).Code != 422 {
		t.Fatal("unverified OTP accepted")
	}
	verified := post("/api/v2/auth/otp/verification", map[string]string{"account": "new@example.test", "type": "register", "verification_id": c.Data.ID, "code": mailer.code})
	if verified.Code != 200 {
		t.Fatal("OTP verification failed")
	}
	registered := post("/api/v2/auth/registration", f.Base)
	if registered.Code != 200 || store.inserts != 1 || len(registered.Result().Cookies()) != 0 {
		t.Fatal("registration failed")
	}
}
