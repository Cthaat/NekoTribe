package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

type resetFixture struct {
	*memorySessions
	fault                      string
	expired, missing, lostRace bool
	marks, writes              int
	otpHash, passwordHash      string
}

func (s *resetFixture) FindOTP(_ context.Context, email, kind, id string) (string, bool, error) {
	if s.fault == "lookup" {
		return "", false, errors.New("reset-private-fixture")
	}
	return s.otpHash, !s.expired && email == "fake@example.test" && kind == "password_reset" && id == "otp_fixture", nil
}
func (s *resetFixture) ResetPasswordAtomic(_ context.Context, email, id, otpHash, hash string) (int, error) {
	if s.fault == "mark" || s.fault == "write" || s.fault == "revoke" {
		return 0, errors.New("reset-private-fixture")
	}
	if s.lostRace || id != "otp_fixture" || otpHash != s.otpHash {
		return resetExpired, nil
	}
	if email != "fake@example.test" || s.missing {
		return resetUserMissing, nil
	}
	s.marks++
	s.writes++
	s.passwordHash = hash
	return resetCommitted, nil
}

func TestSharedPasswordReset(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-password-reset.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Base  map[string]interface{}
		Cases []struct {
			ID, Fault, Message    string
			Patch                 map[string]interface{}
			Expired               bool `json:"expired"`
			Missing               bool `json:"missing_user"`
			LostRace              bool `json:"lost_race"`
			Status, Marks, Writes int
		}
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) != 17 {
		t.Fatalf("unexpected number of cases: %d", len(f.Cases))
	}
	hash, err := bcrypt.GenerateFromPassword([]byte("123456"), 4)
	if err != nil {
		t.Fatal(err)
	}
	codec, _ := fixture(t)
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			body := make(map[string]interface{})
			for k, v := range f.Base {
				body[k] = v
			}
			for k, v := range tc.Patch {
				body[k] = v
			}
			data, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			s := &resetFixture{memorySessions: store(), fault: tc.Fault, expired: tc.Expired, missing: tc.Missing, lostRace: tc.LostRace, otpHash: string(hash)}
			req := httptest.NewRequest("POST", "/api/v2/auth/password-reset", bytes.NewReader(data))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Cookie", "access_token=expired")
			response := httptest.NewRecorder()
			NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{OTPAttemptLimiter: otpAttemptFixture{}}).ServeHTTP(response, req)
			if response.Code != tc.Status || s.marks != tc.Marks || s.writes != tc.Writes {
				t.Fatalf("status=%d marks=%d writes=%d", response.Code, s.marks, s.writes)
			}
			var result struct {
				Message string `json:"message"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil || result.Message != tc.Message {
				t.Fatalf("response message mismatch: %v", err)
			}
			if len(response.Result().Cookies()) != 0 || strings.Contains(response.Body.String(), "reset-private-fixture") || strings.Contains(response.Body.String(), "synthetic-new-password") {
				t.Fatal("response leaked private data or set a cookie")
			}
			if tc.Status == 200 && !matchesLoginPassword(s.passwordHash, strings.TrimSpace(body["new_password"].(string))) {
				t.Fatal("new password hash is not compatible")
			}
		})
	}
}
