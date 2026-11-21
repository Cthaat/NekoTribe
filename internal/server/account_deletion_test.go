package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/crypto/bcrypt"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

type deletionCase struct {
	ID, Fault, Auth string
	Patch           map[string]interface{}
	Status, Writes  int
	Message         *string
}
type deletionFixture struct {
	*memorySessions
	c      deletionCase
	hash   string
	writes int
}

func (s *deletionFixture) SelfProfile(context.Context, int64) (SelfUser, bool, error) {
	if s.c.Fault == "profile" {
		return SelfUser{}, false, errors.New("deletion-private-fixture")
	}
	return SelfUser{UserID: 42, Username: "tester"}, s.c.Fault != "missing", nil
}
func (s *deletionFixture) AccountCredential(context.Context, int64) (LoginAccount, bool, error) {
	if s.c.Fault == "credential" {
		return LoginAccount{}, false, errors.New("deletion-private-fixture")
	}
	return LoginAccount{UserID: 42, PasswordHash: s.hash, Status: "active", Active: s.c.Fault != "inactive"}, true, nil
}
func (s *deletionFixture) DeleteAccountAtomic(_ context.Context, user int64, oldHash, newHash string) (bool, error) {
	if user != 42 || oldHash != s.hash || matchesLoginPassword(newHash, "test-password") {
		return false, errors.New("bad deletion arguments")
	}
	if s.c.Fault == "commit_applied" {
		s.writes++
		return false, errors.New("deletion-private-fixture")
	}
	if s.c.Fault == "changed" {
		return false, nil
	}
	if s.c.Fault != "" && s.c.Fault != "presence" {
		return false, errors.New("deletion-private-fixture")
	}
	s.writes++
	return true, nil
}
func (s *deletionFixture) UserPresence(context.Context, int64) (userPresence, error) {
	if s.c.Fault == "presence" {
		return userPresence{}, errors.New("deletion-private-fixture")
	}
	return userPresence{UserID: 42, OnlineStatus: "offline"}, nil
}
func TestSharedAccountDeletion(t *testing.T) {
	raw, e := os.ReadFile("../../contracts/scenarios/auth-account-deletion.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Base  map[string]interface{}
		Cases []deletionCase
	}
	if e = json.Unmarshal(raw, &f); e != nil {
		t.Fatal(e)
	}
	codec, tokens := fixture(t)
	hash, _ := bcrypt.GenerateFromPassword([]byte("test-password"), 4)
	for _, c := range f.Cases {
		t.Run(c.ID, func(t *testing.T) {
			s := &deletionFixture{memorySessions: store(), c: c, hash: string(hash)}
			s.rows[0].revoked = c.Auth == "revoked"
			body := map[string]interface{}{}
			for k, v := range f.Base {
				body[k] = v
			}
			for k, v := range c.Patch {
				body[k] = v
			}
			encoded, _ := json.Marshal(body)
			req := httptest.NewRequest("DELETE", "/api/v2/users/me", bytes.NewReader(encoded))
			req.Header.Set("Content-Type", "application/json")
			if c.Auth != "none" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			if res.Code != c.Status || s.writes != c.Writes || strings.Contains(res.Body.String(), "deletion-private-fixture") {
				t.Fatalf("status=%d writes=%d", res.Code, s.writes)
			}
			if len(res.Result().Cookies()) != boolInt(c.Status == 200)*2 {
				t.Fatal("cookie mismatch")
			}
			if c.Message != nil {
				var out struct{ Message string }
				_ = json.Unmarshal(res.Body.Bytes(), &out)
				if out.Message != *c.Message {
					t.Fatalf("message=%s", out.Message)
				}
			}
		})
	}
}
