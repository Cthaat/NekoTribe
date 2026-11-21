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

type emailCase struct {
	CommitApplied            bool `json:"commit_applied"`
	ID, Auth, Fault, Message string
	Patch                    map[string]interface{}
	Status, Marks, Writes    int
	Duplicate, Expired       bool
	LostRace                 bool `json:"lost_race"`
	Missing                  bool `json:"missing_user"`
	UniqueRace               bool `json:"unique_race"`
	ClaimCount               int  `json:"claim_count"`
	WriteCount               int  `json:"write_count"`
}
type emailFixture struct {
	*memorySessions
	c             emailCase
	hash          string
	marks, writes int
}

func (s *emailFixture) EmailInUse(_ context.Context, user int64, email string) (bool, error) {
	if user != 42 {
		return false, errors.New("unexpected identity")
	}
	if s.c.Fault == "duplicate" {
		return false, errors.New("email-private-fixture")
	}
	return s.c.Duplicate, nil
}
func (s *emailFixture) FindOTP(_ context.Context, email, kind, id string) (string, bool, error) {
	if s.c.Fault == "lookup" {
		return "", false, errors.New("email-private-fixture")
	}
	return s.hash, !s.c.Expired && s.marks == 0 && email == "new@example.test" && kind == "change_email" && id == "email_fixture", nil
}
func (s *emailFixture) ChangeEmailAtomic(_ context.Context, user int64, email, id, hash string) (emailChangeData, int, error) {
	if s.c.Fault == "commit" && s.c.CommitApplied {
		s.marks++
		s.writes++
		return emailChangeData{}, 0, errors.New("email-private-fixture")
	}
	if s.c.Fault != "" || s.c.ClaimCount > 1 || s.c.WriteCount > 1 {
		return emailChangeData{}, 0, errors.New("email-private-fixture")
	}
	if s.c.LostRace || s.marks > 0 {
		return emailChangeData{}, 1, nil
	}
	if s.c.Missing {
		return emailChangeData{}, 2, nil
	}
	if s.c.UniqueRace {
		return emailChangeData{}, 3, nil
	}
	if user != 42 || email != "new@example.test" || id != "email_fixture" || hash != s.hash {
		return emailChangeData{}, 0, errors.New("unexpected transaction binds")
	}
	s.marks++
	s.writes++
	return emailChangeData{Email: email, VerifiedAt: "2026-01-02T03:04:05.000Z"}, 0, nil
}
func TestSharedEmailChange(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-email-change.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Base  map[string]interface{}
		Cases []emailCase
	}
	if err = json.Unmarshal(raw, &f); err != nil || len(f.Cases) != 25 {
		t.Fatal("invalid fixture", err)
	}
	hash, _ := bcrypt.GenerateFromPassword([]byte("123456"), 4)
	codec, tokens := fixture(t)
	for _, c := range f.Cases {
		t.Run(c.ID, func(t *testing.T) {
			s := &emailFixture{memorySessions: store(), c: c, hash: string(hash)}
			s.rows[0].revoked = c.Auth == "revoked"
			body := map[string]interface{}{}
			for k, v := range f.Base {
				body[k] = v
			}
			for k, v := range c.Patch {
				body[k] = v
			}
			raw, _ := json.Marshal(body)
			req := httptest.NewRequest("PATCH", "/api/v2/users/me/email", bytes.NewReader(raw))
			req.Header.Set("Content-Type", "application/json")
			if c.Auth != "none" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{OTPAttemptLimiter: otpAttemptFixture{}}).ServeHTTP(res, req)
			var result struct {
				Message string
				Data    emailChangeData
			}
			if err = json.Unmarshal(res.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if res.Code != c.Status || result.Message != c.Message || s.marks != c.Marks || s.writes != c.Writes {
				t.Fatalf("status=%d message=%s marks=%d writes=%d", res.Code, result.Message, s.marks, s.writes)
			}
			if len(res.Result().Cookies()) != 0 || strings.Contains(res.Body.String(), "email-private-fixture") || strings.Contains(res.Body.String(), "123456") {
				t.Fatal("private data or cookie escaped")
			}
			if c.Status == 200 {
				if result.Data.Email != "new@example.test" || result.Data.VerifiedAt != "2026-01-02T03:04:05.000Z" {
					t.Fatal("data mismatch")
				}
				again := httptest.NewRecorder()
				req = httptest.NewRequest("PATCH", "/api/v2/users/me/email", bytes.NewReader(raw))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
				NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{OTPAttemptLimiter: otpAttemptFixture{}}).ServeHTTP(again, req)
				if again.Code != 400 || s.writes != 1 {
					t.Fatal("OTP replay accepted")
				}
			}
		})
	}
}

func TestEmailChangeForm(t *testing.T) {
	hash, _ := bcrypt.GenerateFromPassword([]byte("123456"), 4)
	codec, tokens := fixture(t)
	s := &emailFixture{memorySessions: store(), hash: string(hash)}
	req := httptest.NewRequest("PATCH", "/api/v2/users/me/email", strings.NewReader("new_email=new%40example.test&verification_id=email_fixture&code=123456"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Cookie", "access_token="+tokens["access-hs256"])
	res := httptest.NewRecorder()
	NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{OTPAttemptLimiter: otpAttemptFixture{}}).ServeHTTP(res, req)
	if res.Code != 200 || s.marks != 1 || s.writes != 1 {
		t.Fatalf("form status=%d marks=%d writes=%d", res.Code, s.marks, s.writes)
	}
}
