package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

type selfProfileFixture struct {
	*memorySessions
	profile        SelfUser
	calls          int
	missing, fault bool
}

func (s *selfProfileFixture) SelfProfile(_ context.Context, user int64) (SelfUser, bool, error) {
	s.calls++
	if user != 42 {
		return SelfUser{}, false, errors.New("unauthorized user")
	}
	if s.fault {
		return SelfUser{}, false, errors.New("private-profile-fixture")
	}
	return s.profile, !s.missing, nil
}

func TestSharedSelfProfile(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/user-self-profile.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Profile SelfUser
		Cases   []struct {
			ID, Auth, Query           string
			Revoked, Missing, Fault   bool
			TouchFail                 bool `json:"touch_fail"`
			Status, Touches, Profiles int
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil || len(f.Cases) != 10 {
		t.Fatal("invalid fixture", err)
	}
	codec, tokens := fixture(t)
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &selfProfileFixture{memorySessions: store(), profile: f.Profile, missing: tc.Missing, fault: tc.Fault}
			s.rows[0].revoked = tc.Revoked
			s.touchErr = tc.TouchFail
			req := httptest.NewRequest("GET", "/api/v2/users/me"+tc.Query, nil)
			switch tc.Auth {
			case "valid":
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "cookie":
				req.Header.Set("Cookie", "access_token="+tokens["access-hs256"])
			case "bad-cookie":
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
				req.Header.Set("Cookie", "access_token=bad")
			case "expired":
				req.Header.Set("Authorization", "Bearer "+tokens["expired"])
			}
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			if res.Code != tc.Status || s.touches != tc.Touches || s.calls != tc.Profiles {
				t.Fatalf("status=%d touches=%d profiles=%d", res.Code, s.touches, s.calls)
			}
			if strings.Contains(res.Body.String(), "private-profile-fixture") || len(res.Result().Cookies()) != 0 {
				t.Fatal("private error or cookie leaked")
			}
			if tc.Status == 200 {
				if res.Header().Get("Cache-Control") != "private, no-store" {
					t.Fatal("self profile must not be stored by intermediaries")
				}
				var out struct {
					Code    int
					Message string
					Data    SelfUser
					Meta    interface{}
				}
				if err := json.Unmarshal(res.Body.Bytes(), &out); err != nil || out.Code != 200 || out.Message != "success" || out.Meta != nil || !reflect.DeepEqual(out.Data, f.Profile) {
					t.Fatal("profile mismatch", err)
				}
			}
		})
	}
}

func TestSelfProfileStorageAddressAndCredentialRedaction(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/user-self-profile.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtureData struct{ Profile SelfUser }
	if err := json.Unmarshal(raw, &fixtureData); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		base   string
		status int
		want   string
	}{
		{"https://cdn.example.test", 200, "https://cdn.example.test/storage/default-avatar.png"},
		{"https://user:synthetic-secret@example.test", 500, ""},
	} {
		s := &selfProfileFixture{memorySessions: store(), profile: fixtureData.Profile}
		config := RefreshConfig{Storage: storageURLConfig(func(key string) (string, bool) {
			if key == "BASE_URL" {
				return tc.base, true
			}
			return "", false
		})}
		req := httptest.NewRequest("GET", "/api/v2/users/me", nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		res := httptest.NewRecorder()
		NewHandlerWithConfig(codec, s, CorsPolicy{}, config).ServeHTTP(res, req)
		if res.Code != tc.status || strings.Contains(res.Body.String(), "synthetic-secret") {
			t.Fatal("storage result or credential redaction failed")
		}
		if tc.status == 200 {
			var out struct{ Data SelfUser }
			if err := json.Unmarshal(res.Body.Bytes(), &out); err != nil || out.Data.AvatarURL != tc.want {
				t.Fatal("avatar public address mismatch", err)
			}
		}
	}
}
