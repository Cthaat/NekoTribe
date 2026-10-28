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

type analyticsFixture struct {
	*memorySessions
	result        TagAnalytics
	missing, fail bool
	viewer        int64
	name          string
	called        bool
}

func (f *analyticsFixture) ReadTagAnalytics(_ context.Context, viewer int64, name string) (TagAnalytics, bool, error) {
	f.called = true
	f.viewer = viewer
	f.name = name
	if f.fail {
		return TagAnalytics{}, false, errors.New("private-tag-analytics-error")
	}
	return f.result, !f.missing, nil
}
func TestTagAnalyticsSharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/tag-analytics.json")
	if err != nil {
		t.Fatal(err)
	}
	var data struct {
		Result TagAnalytics
		Cases  []struct {
			ID, Path, Auth, Name   string
			Status                 int
			Missing, Failure, Zero bool
		}
	}
	if err = json.Unmarshal(raw, &data); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, tc := range data.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &analyticsFixture{memorySessions: store(), result: data.Result, missing: tc.Missing, fail: tc.Failure}
			if tc.Zero {
				s.result = TagAnalytics{Name: "C# cats"}
			}
			if tc.Auth == "revoked" {
				s.rows[0].revoked = true
			}
			req := httptest.NewRequest("GET", tc.Path, nil)
			switch tc.Auth {
			case "valid", "revoked":
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "cookie":
				req.Header.Set("Cookie", "access_token="+tokens["access-hs256"])
			case "bad":
				req.Header.Set("Authorization", "Bearer bad")
			case "bad-cookie":
				req.Header.Set("Cookie", "access_token=bad")
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			if res.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal("analytics response must not be cached")
			}
			if res.Code != tc.Status || strings.Contains(res.Body.String(), "private-tag-analytics-error") {
				t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
			}
			if tc.Name != "" {
				if !s.called || s.viewer != 42 || s.name != tc.Name {
					t.Fatalf("binding viewer=%d name=%q", s.viewer, s.name)
				}
			} else if s.called {
				t.Fatal("unauthorized reached store")
			}
			if tc.Status == 200 {
				var body struct{ Data TagAnalytics }
				if err = json.Unmarshal(res.Body.Bytes(), &body); err != nil || !reflect.DeepEqual(body.Data, s.result) || res.Header().Get("Cache-Control") != "private, no-store" {
					t.Fatalf("body=%s err=%v", res.Body.String(), err)
				}
			}
		})
	}
}
