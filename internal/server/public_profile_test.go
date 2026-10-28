package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

type publicProfileFixture struct {
	*memorySessions
	profile                         PublicUser
	calls                           int
	hidden, offline, missing, fault bool
}

func (s *publicProfileFixture) PublicProfile(_ context.Context, viewer, target int64) (PublicUser, bool, error) {
	s.calls++
	if viewer != 42 || (target != 7 && target != 9007199254740991) || s.fault {
		return PublicUser{}, false, errors.New("private-profile-error")
	}
	if s.missing {
		return PublicUser{}, false, nil
	}
	v := s.profile
	if s.hidden {
		v.OnlineStatus = "hidden"
		v.LastSeenAt = nil
	}
	if s.offline {
		v.OnlineStatus = "offline"
	}
	return v, true, nil
}
func TestSharedPublicProfile(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/user-public-profile.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Profile PublicUser
		Cases   []struct {
			ID, Auth, Target                         string
			Status, Profiles                         int
			Hidden, Offline, Revoked, Missing, Fault bool
			TouchFail                                bool `json:"touch_fail"`
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil || len(f.Cases) != 21 {
		t.Fatal("invalid cases", err)
	}
	codec, tokens := fixture(t)
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &publicProfileFixture{memorySessions: store(), profile: f.Profile, hidden: tc.Hidden, offline: tc.Offline, missing: tc.Missing, fault: tc.Fault}
			s.rows[0].revoked = tc.Revoked
			s.touchErr = tc.TouchFail
			req := httptest.NewRequest("GET", "/api/v2/users/"+tc.Target+"?viewer_id=99", nil)
			switch tc.Auth {
			case "valid":
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "cookie":
				req.Header.Set("Cookie", "access_token="+tokens["access-hs256"])
			case "bad-cookie":
				req.Header.Set("Cookie", "access_token=bad")
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "expired":
				req.Header.Set("Authorization", "Bearer "+tokens["expired"])
			}
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			if res.Code != tc.Status || s.calls != tc.Profiles {
				t.Fatalf("status=%d calls=%d body=%s", res.Code, s.calls, res.Body.String())
			}
			if strings.Contains(res.Body.String(), "private-profile-error") {
				t.Fatal("private error leaked")
			}
			if tc.Status == 200 {
				var out struct {
					Code int
					Data PublicUser
				}
				if err := json.Unmarshal(res.Body.Bytes(), &out); err != nil {
					t.Fatal(err)
				}
				want := f.Profile
				if tc.Hidden {
					want.OnlineStatus = "hidden"
					want.LastSeenAt = nil
				}
				if tc.Offline {
					want.OnlineStatus = "offline"
				}
				if !reflect.DeepEqual(out.Data, want) {
					t.Fatalf("profile differs: %s", res.Body.String())
				}
				if res.Header().Get("Cache-Control") != "private, no-store" {
					t.Fatal("missing no-store")
				}
				for _, key := range []string{"email", "phone", "birth_date", "password"} {
					if strings.Contains(res.Body.String(), fmt.Sprintf("%q:", key)) {
						t.Fatalf("private field %s", key)
					}
				}
			}
		})
	}
}

type publicProfileConnector struct{ state *driverState }
type publicProfileConn struct{ *testConn }

func (c publicProfileConnector) Connect(context.Context) (driver.Conn, error) {
	return &publicProfileConn{&testConn{c.state}}, nil
}
func (c publicProfileConnector) Driver() driver.Driver { return testDriver{} }
func (c *publicProfileConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.sql = q
	c.state.args = args
	when := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	return &alertRows{values: []driver.Value{int64(7), "publicuser", nil, "Public User", "hello", nil, nil, int64(0), int64(2), int64(3), int64(4), int64(5), "hidden", when, "following"}}, nil
}
func TestPublicProfileOracleQueryAndPrivacyMapping(t *testing.T) {
	state := &driverState{}
	db := sql.OpenDB(publicProfileConnector{state})
	defer db.Close()
	v, found, err := (OracleSessions{db}).PublicProfile(context.Background(), 42, 7)
	if err != nil || !found {
		t.Fatal(err)
	}
	if v.UserID != 7 || v.Username != "publicuser" || v.OnlineStatus != "hidden" || v.LastSeenAt != nil || !v.Relationship.IsFollowing {
		t.Fatalf("wrong mapping: %#v", v)
	}
	if len(state.args) != 2 || state.args[0].Name != "viewer_id" || state.args[0].Value != int64(42) || state.args[1].Name != "user_id" || state.args[1].Value != int64(7) {
		t.Fatalf("wrong binds %#v", state.args)
	}
	for _, text := range []string{"v_user_profile_public", "u.is_active=1", "show_online_status", "NUMTODSINTERVAL(90,'SECOND')", "revoked_at IS NULL"} {
		if !strings.Contains(state.sql, text) {
			t.Fatalf("missing %s", text)
		}
	}
	if strings.Contains(strings.ToLower(state.sql), "email") {
		t.Fatal("private field selected")
	}
}
