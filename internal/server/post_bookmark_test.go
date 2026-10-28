package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"testing"
)

type bookmarkFixture struct {
	*memorySessions
	visible        bool
	loseVisibility bool
	saved          bool
	writes         int
	viewer         int64
}

func (s *bookmarkFixture) SetPostBookmark(_ context.Context, viewer, id int64, saved bool) (bool, error) {
	s.viewer = viewer
	if id == 500 {
		return false, errors.New("private database error")
	}
	if !s.visible || id != 1 || s.loseVisibility {
		return false, nil
	}
	s.writes++
	s.saved = saved
	return true, nil
}

func TestBookmarkRequiresSessionVisibilityAndIsIdempotent(t *testing.T) {
	codec, tokens := fixture(t)
	s := &bookmarkFixture{memorySessions: store(), visible: true}
	handler := NewHandler(codec, s, CorsPolicy{})
	request := func(method, path, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	for _, tc := range []struct {
		method, path, token string
		status              int
	}{
		{"POST", "/api/v2/posts/1/bookmarks", "", 401},
		{"POST", "/api/v2/posts/01/bookmarks", tokens["access-hs256"], 400},
		{"POST", "/api/v2/posts/2/bookmarks", tokens["access-hs256"], 404},
		{"DELETE", "/api/v2/posts/2/bookmarks", tokens["access-hs256"], 404},
		{"POST", "/api/v2/posts/500/bookmarks", tokens["access-hs256"], 500},
	} {
		w := request(tc.method, tc.path, tc.token)
		if w.Code != tc.status {
			t.Fatalf("%s %s: %d %s", tc.method, tc.path, w.Code, w.Body.String())
		}
	}
	if s.writes != 0 {
		t.Fatal("invalid requests changed state")
	}
	for _, tc := range []struct {
		method string
		saved  bool
	}{{"POST", true}, {"POST", true}, {"DELETE", false}, {"DELETE", false}} {
		w := request(tc.method, "/api/v2/posts/1/bookmarks?user_id=99", tokens["access-hs256"])
		var v struct {
			Data struct {
				PostID int64 `json:"post_id"`
				Saved  bool  `json:"is_bookmarked"`
			} `json:"data"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &v) != nil || v.Data.PostID != 1 || v.Data.Saved != tc.saved || s.saved != tc.saved || s.viewer != 42 {
			t.Fatalf("unexpected response %s", w.Body.String())
		}
	}
	s.loseVisibility = true
	w := request("POST", "/api/v2/posts/1/bookmarks", tokens["access-hs256"])
	if w.Code != 404 || s.saved {
		t.Fatalf("lost visibility: %d %s", w.Code, w.Body.String())
	}
}
