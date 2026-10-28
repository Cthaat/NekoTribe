package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
)

type postListFixture struct {
	*postFixture
	query PostListQuery
	total int64
	empty bool
}

func (s *postListFixture) ListVisiblePosts(_ context.Context, viewer *int64, query PostListQuery) ([]PostDetail, int64, error) {
	s.viewer = viewer
	s.query = query
	if err := s.mark("list"); err != nil {
		return nil, 0, err
	}
	if s.empty {
		return []PostDetail{}, s.total, nil
	}
	return []PostDetail{s.post}, s.total, nil
}

func TestPostListRoute(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/post-detail-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtureData struct{ Post PostDetail }
	if err = json.Unmarshal(raw, &fixtureData); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	cases := []struct {
		name, query, token, fault string
		empty                     bool
		wantStatus                int
		wantEvents                []string
	}{
		{"public", "?page=2&page_size=1&q=%20%23%23Cat_%25%20&sort=popular&viewer_id=99", "", "", false, 200, []string{"list", "author", "media-ready", "media", "tags", "mentions"}},
		{"following requires auth", "?timeline=following", "", "", false, 401, nil},
		{"mentions requires auth", "?timeline=mentions", "", "", false, 401, nil},
		{"authorized following", "?timeline=following", "valid", "", false, 200, []string{"list", "author", "media-ready", "media", "tags", "mentions"}},
		{"invalid token", "", "bad", "", false, 401, nil},
		{"empty without media check", "", "", "", true, 200, []string{"list"}},
		{"repository failure", "", "", "list", false, 500, []string{"list"}},
		{"media unavailable", "", "", "media-ready", false, 503, []string{"list", "author", "media-ready"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := &postListFixture{postFixture: &postFixture{memorySessions: store(), post: fixtureData.Post}, total: 3, empty: tc.empty}
			store.fault = tc.fault
			req := httptest.NewRequest("GET", "/api/v2/posts"+tc.query, nil)
			if tc.token == "valid" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			if tc.token == "bad" {
				req.Header.Set("Authorization", "Bearer invalid")
			}
			res := httptest.NewRecorder()
			NewHandler(codec, store, CorsPolicy{}).ServeHTTP(res, req)
			if res.Code != tc.wantStatus || !reflect.DeepEqual(store.events, tc.wantEvents) {
				t.Fatalf("status=%d events=%v body=%s", res.Code, store.events, res.Body.String())
			}
			if tc.name == "following requires auth" || tc.name == "mentions requires auth" {
				var body struct {
					Message string `json:"message"`
				}
				if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil || body.Message != "未认证或 token 无效" {
					t.Fatalf("wrong authorization message: %s", res.Body.String())
				}
			}
			if tc.name == "public" {
				if store.viewer != nil || store.query.Page.Page != 2 || store.query.Page.PageSize != 1 || store.query.Search != "##cat_%" || store.query.TagSearch != "cat_%" || store.query.Sort != "popular" {
					t.Fatalf("unexpected query: %#v viewer=%v", store.query, store.viewer)
				}
				var result struct {
					Data []PostDetail `json:"data"`
					Meta struct {
						Page     float64 `json:"page"`
						PageSize float64 `json:"page_size"`
						Total    int64   `json:"total"`
						HasNext  bool    `json:"has_next"`
					} `json:"meta"`
				}
				if err := json.Unmarshal(res.Body.Bytes(), &result); err != nil {
					t.Fatal(err)
				}
				if len(result.Data) != 1 || !reflect.DeepEqual(result.Data[0], fixtureData.Post) || result.Meta.Page != 2 || result.Meta.PageSize != 1 || result.Meta.Total != 3 || !result.Meta.HasNext {
					t.Fatalf("wrong response: %s", res.Body.String())
				}
			}
			if tc.name == "authorized following" && (store.viewer == nil || *store.viewer != 42 || store.query.Timeline != "following") {
				t.Fatal("wrong authenticated viewer or timeline")
			}
		})
	}
}

func TestPostListSearchUsesFullUnicodeLowercase(t *testing.T) {
	query := parsePostListQuery("q=%C4%B0%20%CE%9F%CE%A3")
	if query.Search != "i\u0307 ος" {
		t.Fatalf("unexpected Unicode lowercase: %q", query.Search)
	}
}

func TestPostListModesAuthorizationAndSort(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		path, mode string
		anonymous  int
	}{
		{"/api/v2/posts/trending?sort=oldest", "trending", 200},
		{"/api/v2/users/me/posts?viewer_id=99", "me", 401},
		{"/api/v2/users/me/bookmarks?viewer_id=99", "bookmarks", 401},
		{"/api/v2/users/me/likes?sort=oldest&viewer_id=99", "likes", 401},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			for _, authenticated := range []bool{false, true} {
				s := &postListFixture{postFixture: &postFixture{memorySessions: store()}, empty: true}
				req := httptest.NewRequest("GET", tc.path, nil)
				if authenticated {
					req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
				}
				res := httptest.NewRecorder()
				NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
				want := tc.anonymous
				if authenticated {
					want = 200
				}
				if res.Code != want {
					t.Fatalf("authenticated=%t status=%d body=%s", authenticated, res.Code, res.Body.String())
				}
				if want == 200 && s.query.Mode != tc.mode {
					t.Fatalf("wrong mode: %#v", s.query)
				}
				if tc.mode == "trending" && want == 200 && s.query.Sort != "popular" {
					t.Fatal("trending sort was not forced")
				}
				if tc.mode != "trending" && authenticated && (s.viewer == nil || *s.viewer != 42) {
					t.Fatal("wrong viewer")
				}
			}
		})
	}
}

func TestScopedPostListsValidateAndBindTarget(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		path, mode, tag string
		target          int64
	}{
		{"/api/v2/users/7/posts", "user", "", 7},
		{"/api/v2/tags/C%23%20cats/posts", "tag", "C# cats", 0},
		{"/api/v2/posts/9/replies", "replies", "", 9},
		{"/api/v2/posts/%31/replies", "replies", "", 1},
		{"/api/v2/posts/9/retweets", "retweets", "", 9},
	} {
		for _, authenticated := range []bool{false, true} {
			s := &postListFixture{postFixture: &postFixture{memorySessions: store()}, empty: true}
			req := httptest.NewRequest("GET", tc.path, nil)
			if authenticated {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			want := 401
			if authenticated {
				want = 200
			}
			if res.Code != want {
				t.Fatalf("%s authenticated=%t status=%d body=%s", tc.path, authenticated, res.Code, res.Body.String())
			}
			if authenticated && (s.query.Mode != tc.mode || s.query.TargetID != tc.target || s.query.TagName != tc.tag || s.viewer == nil || *s.viewer != 42) {
				t.Fatalf("%s query=%#v", tc.path, s.query)
			}
		}
	}
	for _, path := range []string{"/api/v2/users/01/posts", "/api/v2/posts/1.5/replies", "/api/v2/posts/0x1/retweets", "/api/v2/users/9007199254740992/posts"} {
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		res := httptest.NewRecorder()
		NewHandler(codec, store(), CorsPolicy{}).ServeHTTP(res, req)
		if res.Code != 400 {
			t.Fatalf("%s status=%d", path, res.Code)
		}
	}
}
