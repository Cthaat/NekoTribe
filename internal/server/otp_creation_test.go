package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

type createOTPFixture struct {
	*memorySessions
	event   OTPEvent
	inserts int
	fault   string
	updates int
}

func (s *createOTPFixture) FindOTP(_ context.Context, account, kind, id string) (string, bool, error) {
	return s.event.Hash, s.inserts == 1 && s.event.Account == account && s.event.Kind == kind && s.event.ID == id, nil
}
func (s *createOTPFixture) MarkOTPVerified(context.Context, string) error { s.updates++; return nil }
func (s *createOTPFixture) OTPVerifiedAt(context.Context, string) (*time.Time, error) {
	at := s.event.Expires.Add(-300 * time.Second)
	return &at, nil
}

func (s *createOTPFixture) NextOTPID(context.Context) (int64, error) { return 123, nil }
func (s *createOTPFixture) InsertOTP(_ context.Context, e OTPEvent) error {
	if s.fault == "insert" {
		return errors.New("otp-private-fixture")
	}
	s.event = e
	s.inserts++
	return nil
}

type createMailFixture struct {
	store *createOTPFixture
	sends int
	code  string
	fault string
}

func (s *createMailFixture) SendOTP(_ context.Context, to, code string) error {
	if s.store.inserts != 1 {
		return errors.New("wrong order")
	}
	s.sends++
	s.code = code
	if s.fault == "mail" {
		return errors.New("otp-private-fixture")
	}
	return nil
}
func TestSharedOTPCreation(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/auth-otp-creation.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []struct {
			ID                     string
			Body                   json.RawMessage
			Fault                  string
			Status, Inserts, Sends int
		}
	}
	if err = json.Unmarshal(data, &f); err != nil || len(f.Cases) != 12 {
		t.Fatal(err)
	}
	codec, _ := fixture(t)
	now := time.Date(2026, 1, 2, 3, 4, 5, 123000000, time.UTC)
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			store := &createOTPFixture{memorySessions: store(), fault: tc.Fault}
			mail := &createMailFixture{store: store, fault: tc.Fault}
			h := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{clock: func() time.Time { return now }, otpMailer: mail})
			req := httptest.NewRequest("POST", "/api/v2/auth/otp", bytes.NewReader(tc.Body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Cookie", "access_token=expired")
			res := httptest.NewRecorder()
			h.ServeHTTP(res, req)
			if res.Code != tc.Status || store.inserts != tc.Inserts || mail.sends != tc.Sends || strings.Contains(res.Body.String(), "otp-private-fixture") || len(res.Result().Cookies()) != 0 {
				t.Fatalf("status=%d inserts=%d sends=%d body=%s", res.Code, store.inserts, mail.sends, res.Body.String())
			}
			if tc.Status == 200 {
				var out struct {
					Data struct {
						Account string
						ID      string `json:"verification_id"`
						Expires string `json:"expires_at"`
					}
				}
				if err := json.Unmarshal(res.Body.Bytes(), &out); err != nil {
					t.Fatal(err)
				}
				if out.Data.Account != "fake@example.test" || out.Data.ID != store.event.ID || out.Data.Expires != "2026-01-02T03:09:05.123Z" || !regexp.MustCompile(`^otp_[0-9a-f-]{36}$`).MatchString(out.Data.ID) || !regexp.MustCompile(`^[0-9]{6}$`).MatchString(mail.code) || !matchesLoginPassword(store.event.Hash, mail.code) || strings.Contains(res.Body.String(), mail.code) {
					t.Fatal("invalid creation response")
				}
				verification, _ := json.Marshal(map[string]string{"account": out.Data.Account, "type": store.event.Kind, "verification_id": out.Data.ID, "code": mail.code})
				verifyReq := httptest.NewRequest("POST", "/api/v2/auth/otp/verification", bytes.NewReader(verification))
				verifyReq.Header.Set("Content-Type", "application/json")
				verifyRes := httptest.NewRecorder()
				h.ServeHTTP(verifyRes, verifyReq)
				if verifyRes.Code != 200 || store.updates != 1 {
					t.Fatal("created OTP did not verify")
				}
			}
		})
	}
}
