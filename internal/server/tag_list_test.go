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

type tagListFixture struct {
	*memorySessions
	query  TagListQuery
	items  []TagItem
	fail   bool
	called bool
}

func (f *tagListFixture) ListTags(_ context.Context, query TagListQuery) ([]TagItem, int64, error) {
	f.called = true
	f.query = query
	if f.fail {
		return nil, 0, errors.New("private-tag-database-error")
	}
	return f.items, 3, nil
}
func TestTagListSharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/tag-list.json")
	if err != nil {
		t.Fatal(err)
	}
	var data struct {
		Items []TagItem
		Cases []struct {
			ID, Path, Auth string
			Status         int
			Q              *string
			Trending       bool
			Page, Size     float64
			Failure        bool
		}
	}
	if err = json.Unmarshal(raw, &data); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, tc := range data.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &tagListFixture{memorySessions: store(), items: data.Items, fail: tc.Failure}
			if tc.Auth == "revoked" {
				s.rows[0].revoked = true
			}
			req := httptest.NewRequest("GET", tc.Path, nil)
			switch tc.Auth {
			case "valid", "revoked":
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "cookie":
				req.Header.Set("Cookie", "access_token="+tokens["access-hs256"])
			case "bad-cookie":
				req.Header.Set("Cookie", "access_token=bad")
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "bad":
				req.Header.Set("Authorization", "Bearer bad")
			}
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			if res.Code != tc.Status || strings.Contains(res.Body.String(), "private-tag-database-error") {
				t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
			}
			if tc.Status == 200 {
				if !s.called || s.query.Trending != tc.Trending || !reflect.DeepEqual(s.query.Q, tc.Q) || s.query.Page.Page != tc.Page || s.query.Page.PageSize != tc.Size {
					t.Fatalf("query=%#v", s.query)
				}
				var body struct {
					Data []TagItem
					Meta struct {
						Page  float64 `json:"page"`
						Size  float64 `json:"page_size"`
						Total int64   `json:"total"`
						Next  bool    `json:"has_next"`
					}
				}
				if err = json.Unmarshal(res.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(body.Data, data.Items) || body.Meta.Page != tc.Page || body.Meta.Size != tc.Size || body.Meta.Total != 3 || body.Meta.Next != (tc.Page*tc.Size < 3) {
					t.Fatalf("body=%s", res.Body.String())
				}
			}
		})
	}
}
