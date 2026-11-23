package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

type accountResourceFixture struct{ *memorySessions }

func (s *accountResourceFixture) AccountUsage(_ context.Context, actor int64) (accountUsage, error) {
	var usage accountUsage
	if actor != 42 {
		return usage, errSessionStore
	}
	usage.Media.Bytes, usage.Media.Files = 768, 2
	usage.History.Conversations = 2
	return usage, nil
}

func (s *accountResourceFixture) AccountExport(_ context.Context, actor int64) (accountExport, error) {
	if actor != 42 {
		return accountExport{}, errSessionStore
	}
	content := "<b>post content</b>\nsecond line"
	return accountExport{
		Posts:     []exportPost{{exportBookmark{1, "2026-11-21T00:00:00.000Z"}, &content}},
		Bookmarks: []exportBookmark{{4, "2026-11-21T00:00:00.000Z"}},
	}, nil
}

func TestAccountResourcesRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	handler := NewHandler(codec, &accountResourceFixture{store()}, CorsPolicy{})
	request := func(path string, authenticated bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "/api/v2/users/me/"+path, nil)
		if authenticated {
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, req)
		return result
	}

	t.Run("owner usage", func(t *testing.T) {
		res := request("usage?user_id=77", true)
		var body struct{ Data accountUsage }
		if res.Code != 200 || res.Header().Get("Cache-Control") != "private, no-store" ||
			json.Unmarshal(res.Body.Bytes(), &body) != nil || body.Data.Media.Bytes != 768 ||
			body.Data.History.Conversations != 2 || body.Data.Quota.Window != 60 {
			t.Fatal(res.Code, res.Body.String())
		}
	})
	t.Run("owner attachment formats", func(t *testing.T) {
		res := request("export?format=json", true)
		var body accountExport
		if res.Code != 200 || !strings.Contains(res.Header().Get("Content-Disposition"), ".json") ||
			json.Unmarshal(res.Body.Bytes(), &body) != nil || len(body.Posts) != 1 ||
			len(body.Bookmarks) != 1 || body.Bookmarks[0].PostID != 4 {
			t.Fatal(res.Code, res.Body.String())
		}
		res = request("export?format=markdown", true)
		if res.Code != 200 || !strings.HasPrefix(res.Header().Get("Content-Type"), "text/markdown") ||
			!strings.Contains(res.Body.String(), "    <b>post content</b>\n    second line") {
			t.Fatal(res.Code, res.Body.String())
		}
	})
	t.Run("authentication and invalid format", func(t *testing.T) {
		if result := request("export", false); result.Code != 401 {
			t.Fatal(result.Code)
		}
		if result := request("export?format=csv", true); result.Code != 400 {
			t.Fatal(result.Code)
		}
	})
}
