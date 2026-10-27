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
	"time"
)

type otpFixture struct {
	*memorySessions
	account, kind, id, hash string
	when                    time.Time
	expired                 bool
	fault                   string
	updates                 int
}

func (s *otpFixture) FindOTP(_ context.Context, account, kind, id string) (string, bool, error) {
	if s.fault == "lookup" {
		return "", false, errors.New("otp-private-fixture")
	}
	return s.hash, !s.expired && s.account == account && s.kind == kind && s.id == id, nil
}
func (s *otpFixture) MarkOTPVerified(_ context.Context, _ string) error {
	if s.fault == "update" {
		return errors.New("otp-private-fixture")
	}
	s.updates++
	return nil
}
func (s *otpFixture) OTPVerifiedAt(_ context.Context, _ string) (*time.Time, error) {
	if s.fault == "readback" {
		return nil, errors.New("otp-private-fixture")
	}
	return &s.when, nil
}
func TestSharedOTPVerification(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/auth-otp-verification.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Raw   json.RawMessage `json:"fixture"`
		Cases []struct {
			ID              string
			Body            json.RawMessage
			Expired, Repeat bool
			Fault           string
			Status, Updates int
		}
	}
	if err = json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	var base struct {
		Account, Type, Hash string
		VerificationID      string `json:"verification_id"`
		VerifiedAt          string `json:"verified_at"`
	}
	if err = json.Unmarshal(f.Raw, &base); err != nil || len(f.Cases) != 16 {
		t.Fatal(err)
	}
	codec, _ := fixture(t)
	when, err := time.Parse(time.RFC3339Nano, base.VerifiedAt)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &otpFixture{memorySessions: store(), account: base.Account, kind: base.Type, id: base.VerificationID, hash: base.Hash, when: when, expired: tc.Expired, fault: tc.Fault}
			handler := NewHandler(codec, s, CorsPolicy{})
			n := 1
			if tc.Repeat {
				n = 2
			}
			for i := 0; i < n; i++ {
				req := httptest.NewRequest("POST", "/api/v2/auth/otp/verification", bytes.NewReader(tc.Body))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Cookie", "access_token=expired")
				res := httptest.NewRecorder()
				handler.ServeHTTP(res, req)
				if res.Code != tc.Status || strings.Contains(res.Body.String(), "otp-private-fixture") || len(res.Result().Cookies()) != 0 {
					t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
				}
				if tc.Status == 200 {
					var out struct {
						Data struct {
							Account    string
							Verified   bool
							VerifiedAt string `json:"verified_at"`
						}
					}
					if err := json.Unmarshal(res.Body.Bytes(), &out); err != nil || out.Data.Account != base.Account || !out.Data.Verified || out.Data.VerifiedAt != base.VerifiedAt {
						t.Fatalf("bad response %s", res.Body.String())
					}
				}
			}
			if s.updates != tc.Updates {
				t.Fatalf("updates=%d", s.updates)
			}
		})
	}
}
