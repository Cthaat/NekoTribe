package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/crypto/bcrypt"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestFactorManagementNativeRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	for _, action := range []string{"setup", "confirm", "disable"} {
		method, path := "POST", "/api/v2/users/me/two-factor/"+action
		if action == "disable" {
			method, path = "DELETE", "/api/v2/users/me/two-factor"
		}
		req := httptest.NewRequest(method, path, strings.NewReader(`{"password":"test-password","code":"123456"}`))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		res := httptest.NewRecorder()
		NewHandler(codec, store(), CorsPolicy{}).ServeHTTP(res, req)
		if res.Code == 404 || res.Code == 405 {
			t.Fatalf("native %s missing: %d", action, res.Code)
		}
	}
}

type managementCase struct {
	ID, Action, Auth, Secret, Fault string
	Patch                           map[string]interface{}
	Status, Writes                  int
	Message                         *string
}
type managementFixture struct {
	*memorySessions
	c                  managementCase
	secret             FactorSecret
	hash, recoveryHash string
	writes             int
	mutation           FactorMutation
}

func (s *managementFixture) AccountCredential(context.Context, int64) (LoginAccount, bool, error) {
	if s.c.Fault == "credential" {
		return LoginAccount{}, false, errSessionStore
	}
	return LoginAccount{UserID: 42, Active: s.c.Fault != "inactive", Status: "active", PasswordHash: s.hash}, s.c.Fault != "missing", nil
}
func (s *managementFixture) CheckTwoFactorSchema(context.Context) error {
	if s.c.Fault == "schema" {
		return errSessionStore
	}
	return nil
}
func (s *managementFixture) SelfProfile(context.Context, int64) (SelfUser, bool, error) {
	if s.c.Fault == "profile" {
		return SelfUser{}, false, errSessionStore
	}
	return SelfUser{UserID: 42, Username: "tester", Email: "fake@example.test"}, true, nil
}
func (s *managementFixture) FindFactorSecret(context.Context, int64) (FactorSecret, bool, error) {
	if s.c.Fault == "secret" {
		return FactorSecret{}, false, errSessionStore
	}
	return s.secret, s.c.Secret != "absent", nil
}
func (s *managementFixture) FindRecoveryCodes(context.Context, int64) ([]RecoveryCode, error) {
	if s.c.Fault == "recovery" {
		return nil, errSessionStore
	}
	return []RecoveryCode{{ID: 1, Hash: s.recoveryHash}}, nil
}
func (s *managementFixture) ApplyFactorMutation(_ context.Context, user int64, m FactorMutation) (int, error) {
	if user != 42 {
		return 0, errors.New("wrong owner")
	}
	s.mutation = m
	switch s.c.Fault {
	case "write", "commit":
		return 0, errSessionStore
	case "changed":
		return factorChanged, nil
	case "consume":
		if m.RecoveryID != 1 {
			return 0, errSessionStore
		}
		return factorRecoveryUsed, nil
	case "commit_applied":
		s.writes++
		return 0, errSessionStore
	}
	s.writes++
	return factorApplied, nil
}
func TestSharedFactorManagement(t *testing.T) {
	raw, e := os.ReadFile("../../contracts/scenarios/auth-two-factor-management.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Base                       map[string]interface{}
		Secret, RecoveryCode, TOTP string
		ClockUnix                  int64
		Cases                      []managementCase
	}
	if e = json.Unmarshal(raw, &f); e != nil {
		t.Fatal(e)
	}
	codec, tokens := fixture(t)
	hash, _ := bcrypt.GenerateFromPassword([]byte("test-password"), 4)
	rh, _ := bcrypt.GenerateFromPassword([]byte(normalizeFactorCode(f.RecoveryCode)), 4)
	for _, c := range f.Cases {
		t.Run(c.ID, func(t *testing.T) {
			s := &managementFixture{memorySessions: store(), c: c, hash: string(hash), recoveryHash: string(rh)}
			s.rows[0].revoked = c.Auth == "revoked"
			value := f.Secret
			if c.Fault == "base32" {
				value = "INVALID!"
			}
			s.secret = factorSecretForTest(t, value)
			s.secret.Enabled = c.Secret == "enabled" || (c.Secret == "" && c.Action == "disable")
			if c.Fault == "cipher" {
				s.secret.Tag = "bad"
			}
			body := map[string]interface{}{}
			for k, v := range f.Base {
				body[k] = v
			}
			for k, v := range c.Patch {
				body[k] = v
			}
			if body["code"] == "@totp" {
				body["code"] = f.TOTP
			}
			if body["code"] == "@recovery" {
				body["code"] = f.RecoveryCode
			}
			encoded, _ := json.Marshal(body)
			method, path := "POST", "/api/v2/users/me/two-factor/"+c.Action
			if c.Action == "disable" {
				method, path = "DELETE", "/api/v2/users/me/two-factor"
			}
			req := httptest.NewRequest(method, path, bytes.NewReader(encoded))
			req.Header.Set("Content-Type", "application/json")
			if c.Auth != "none" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{clock: func() time.Time { return time.Unix(f.ClockUnix, 0) }}).ServeHTTP(res, req)
			if res.Code != c.Status || s.writes != c.Writes {
				t.Fatalf("status=%d writes=%d", res.Code, s.writes)
			}
			var out struct {
				Message string
				Data    map[string]interface{}
			}
			if e = json.Unmarshal(res.Body.Bytes(), &out); e != nil {
				t.Fatal(e)
			}
			if c.Message != nil && out.Message != *c.Message {
				t.Fatalf("message=%s", out.Message)
			}
			if len(res.Result().Cookies()) != 0 || strings.Contains(res.Body.String(), "test-password") {
				t.Fatal("credential leakage")
			}
			if c.Status == 200 && c.Action == "setup" {
				plain, e := codec.OpenTwoFactorSecret(s.mutation.New.Encrypted, s.mutation.New.IV, s.mutation.New.Tag)
				if e != nil || plain != out.Data["secret"] || len(plain) != 32 {
					t.Fatal("incompatible generated secret")
				}
				u, e := url.Parse(out.Data["otpauth_url"].(string))
				if e != nil || u.Query().Get("secret") != plain {
					t.Fatal("bad URI")
				}
			}
			if c.Status == 200 && c.Action == "confirm" {
				codes := out.Data["recovery_codes"].([]interface{})
				if len(codes) != 10 || len(s.mutation.RecoveryHashes) != 10 {
					t.Fatal("recovery count")
				}
				for i, code := range codes {
					if !matchesLoginPassword(s.mutation.RecoveryHashes[i], normalizeFactorCode(code.(string))) {
						t.Fatal("incompatible recovery hash")
					}
				}
			}
		})
	}
}
