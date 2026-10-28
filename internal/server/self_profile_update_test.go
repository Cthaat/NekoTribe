package server

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

type profileUpdateFixture struct {
	*selfProfileFixture
	fields     map[string]string
	writes     int
	updateFail bool
}

func (s *profileUpdateFixture) UpdateSelfProfile(_ context.Context, user int64, fields map[string]string) error {
	s.writes++
	if user != 42 {
		return errors.New("wrong user")
	}
	s.fields = fields
	if s.updateFail {
		return errors.New("private-update-fixture")
	}
	return nil
}
func TestSharedSelfProfileUpdate(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/user-self-profile-update.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []struct {
			ID, Auth                  string
			Body                      json.RawMessage
			Fields                    map[string]string
			Revoked                   bool
			TouchFail                 bool `json:"touch_fail"`
			UpdateFail                bool `json:"update_fail"`
			ProfileFail               bool `json:"profile_fail"`
			Missing                   bool
			Updates, Profiles, Status int
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil || len(f.Cases) != 18 {
		t.Fatal("invalid cases", err)
	}
	codec, tokens := fixture(t)
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			base := &selfProfileFixture{memorySessions: store(), profile: SelfUser{UserID: 42}, missing: tc.Missing, fault: tc.ProfileFail}
			base.rows[0].revoked = tc.Revoked
			base.touchErr = tc.TouchFail
			s := &profileUpdateFixture{selfProfileFixture: base, updateFail: tc.UpdateFail}
			req := httptest.NewRequest("PATCH", "/api/v2/users/me?user_id=99", bytes.NewReader(tc.Body))
			req.Header.Set("Content-Type", "application/json")
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
			if res.Code != tc.Status || s.writes != tc.Updates || s.calls != tc.Profiles {
				t.Fatalf("status %d writes %d profiles %d", res.Code, s.writes, s.calls)
			}
			if s.writes > 0 && !reflect.DeepEqual(s.fields, tc.Fields) {
				t.Fatalf("fields %#v", s.fields)
			}
			if bytes.Contains(res.Body.Bytes(), []byte("private-")) {
				t.Fatal("private error leaked")
			}
			if tc.Status == 200 && (res.Header().Get("Cache-Control") != "private, no-store" || len(res.Result().Cookies()) != 0) {
				t.Fatal("cache or cookie")
			}
		})
	}
}

func TestProfileUpdateOracleBindsOnlyAllowedFields(t *testing.T) {
	state := &driverState{}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	repo := OracleSessions{db}
	if err := repo.UpdateSelfProfile(context.Background(), 42, map[string]string{"bio": "value';--", "birth_date": "", "user_id": "99"}); err != nil {
		t.Fatal(err)
	}
	if state.commits != 1 || strings.Contains(state.sql, "value';--") || strings.Contains(state.sql, "display_name") || strings.Contains(state.sql, "user_id = :user_id,") || !strings.Contains(state.sql, "WHERE user_id = :user_id") || !strings.Contains(state.sql, "TO_DATE(:birth_date") {
		t.Fatalf("unsafe SQL: %s", state.sql)
	}
	values := map[string]interface{}{}
	for _, arg := range state.args {
		values[arg.Name] = arg.Value
	}
	if !reflect.DeepEqual(values, map[string]interface{}{"user_id": int64(42), "bio": "value';--", "birth_date": nil}) {
		t.Fatalf("wrong binds: %#v", values)
	}
	if err := repo.UpdateSelfProfile(context.Background(), 42, map[string]string{}); err != nil || state.commits != 1 {
		t.Fatal("empty update must not commit", err)
	}
}
