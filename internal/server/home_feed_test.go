package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHomeRecommendedUsesExplicitSharedRank(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/requirements/home-feed.json")
	if err != nil {
		t.Fatal(err)
	}
	var expected struct{ RecommendationRecency, RecommendationScore string }
	if err := json.Unmarshal(raw, &expected); err != nil || expected.RecommendationScore == "" || expected.RecommendationRecency == "" {
		t.Fatalf("invalid shared ranking: %v", err)
	}
	viewer := int64(42)
	q := parsePostListQuery("timeline=recommended&sort=popular")
	q.Mode = "all"
	_, anonymous, _, _ := postListSQL(nil, q, false)
	if !strings.Contains(anonymous, "ORDER BY "+expected.RecommendationRecency+")") ||
		strings.Contains(anonymous, expected.RecommendationScore) || strings.Contains(anonymous, recommendationFeedbackSQL.FeedOrder) {
		t.Fatal("anonymous recommended did not use stable recency")
	}
	count, loggedIn, _, _ := postListSQL(&viewer, q, true)
	if !strings.Contains(loggedIn, expected.RecommendationScore) ||
		!strings.Contains(loggedIn, recommendationFeedbackSQL.FeedOrder+", (") ||
		!strings.Contains(loggedIn, expected.RecommendationRecency) ||
		!strings.HasSuffix(loggedIn, " ORDER BY rn") ||
		!strings.Contains(count, recommendationFeedbackSQL.FeedFilter) {
		t.Fatal("recommended did not use shared ranking after feedback")
	}
	count, noFeedback, _, _ := postListSQL(&viewer, q, false)
	if !strings.Contains(noFeedback, expected.RecommendationScore) ||
		strings.Contains(noFeedback, recommendationFeedbackSQL.FeedOrder) ||
		strings.Contains(count, recommendationFeedbackSQL.FeedFilter) {
		t.Fatal("recommended scoring should continue without the feedback table")
	}
	for _, tc := range []struct{ mode, query string }{
		{"all", "timeline=recommended&q=cat"}, {"all", "timeline=home"}, {"all", "timeline=following"},
		{"all", "timeline=mentions"}, {"trending", "timeline=recommended"}, {"user", "timeline=recommended"},
	} {
		query := parsePostListQuery(tc.query)
		query.Mode = tc.mode
		_, other, _, _ := postListSQL(&viewer, query, false)
		if strings.Contains(other, expected.RecommendationScore) || strings.HasSuffix(other, " ORDER BY rn") {
			t.Fatalf("changed existing order for %s %s", tc.mode, tc.query)
		}
	}
}

type homeActivityFixture struct {
	*postMarkdownFixture
	calls []listQueryCall
}

type homeActivityConn struct {
	*postMarkdownFixtureConn
	f *homeActivityFixture
}

func (f *homeActivityFixture) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := f.postMarkdownFixture.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return &homeActivityConn{postMarkdownFixtureConn: conn.(*postMarkdownFixtureConn), f: f}, nil
}

func (c *homeActivityConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.f.calls = append(c.f.calls, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if !strings.Contains(query, homeFeed.GroupActivity) {
		return c.postMarkdownFixtureConn.QueryContext(ctx, query, args)
	}
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	if len(args) != 3 || bind("viewer_id") != int64(42) || bind("start_row") != bind("end_row") {
		return nil, errors.New("invalid group activity scope")
	}
	start, ok := bind("start_row").(float64)
	if !ok {
		return nil, errors.New("invalid group activity page")
	}
	if start > 3 {
		values := make([]driver.Value, 16)
		values[0], values[1] = int64(1), int64(3)
		return &alertRows{values: values}, nil
	}
	created := time.Date(2026, 11, 23, 12, 0, 0, 0, time.UTC)
	return &alertRows{values: []driver.Value{int64(1), int64(3), int64(5), int64(7), int64(42),
		"excerpt", "https://example.test/group-image.png", int64(0), int64(1), int64(9), int64(2),
		int64(8), created, created, int64(1), "Arcade"}}, nil
}

func TestHomeGroupActivityUsesSharedScopeAndHydratesRows(t *testing.T) {
	codec, tokens := fixture(t)
	f := &homeActivityFixture{postMarkdownFixture: newPostMarkdownFixture(t, postPollTarget{group: 7, post: 5})}
	markdown := "# Arcade\n"
	f.body = &markdown
	f.options = []string{"first", "second"}
	db := sql.OpenDB(f)
	defer db.Close()
	repo := postPollHTTPRepository{OracleSessions{db}, store()}
	h := NewHandler(codec, repo, CorsPolicy{})
	request := func(page string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(http.MethodGet, "/api/v2/feed/groups?page="+page+"&page_size=1&viewer_id=9", nil)
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusOK || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("group feed status %d: %s", w.Code, w.Body)
		}
		return w
	}
	w := request("2")
	var result struct {
		Data []groupActivityPost `json:"data"`
		Meta struct {
			Page     int  `json:"page"`
			PageSize int  `json:"page_size"`
			Total    int  `json:"total"`
			HasNext  bool `json:"has_next"`
		} `json:"meta"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || len(result.Data) != 1 ||
		result.Meta.Page != 2 || result.Meta.PageSize != 1 || result.Meta.Total != 3 || !result.Meta.HasNext {
		t.Fatalf("group activity page %s: %v", w.Body, err)
	}
	item := result.Data[0]
	if item.GroupName != "Arcade" || item.Group != 7 || item.ID != 5 || item.Author.UserID != 42 ||
		!item.Liked || !item.Announcement || item.Markdown == nil || *item.Markdown != markdown ||
		item.Poll == nil || len(item.Poll.Options) != 2 || len(item.Media) != 1 ||
		item.Media[0] != "https://example.test/group-image.png" {
		t.Fatalf("group activity post lost standard data: %+v", item)
	}
	first := f.calls[0]
	if !strings.HasPrefix(first.sql, "SELECT ") || !strings.HasSuffix(first.sql, "ORDER BY created_at DESC, post_id DESC") ||
		directFixtureBind(first.args, "start_row") != float64(2) ||
		directFixtureBind(first.args, "end_row") != float64(2) {
		t.Fatalf("incorrect native Oracle query %+v", first)
	}
	for _, predicate := range []string{"m.user_id=:viewer_id AND m.status='active'", "g.is_active=1 AND g.is_deleted=0",
		"a.is_active=1", "WHERE p.is_deleted=0", "b.user_id=:viewer_id AND b.target_user_id=p.author_id",
		"b.target_user_id=:viewer_id AND b.user_id=p.author_id"} {
		if !strings.Contains(first.sql, predicate) {
			t.Fatalf("activity does not scope against %s", predicate)
		}
	}
	f.calls = nil
	w = request("4")
	if len(f.calls) != 1 || !strings.Contains(w.Body.String(), `"data":[]`) || !strings.Contains(w.Body.String(), `"has_next":false`) {
		t.Fatalf("empty page should avoid hydration: %s", w.Body)
	}
}

func TestHomeGroupActivityRequiresAuthentication(t *testing.T) {
	recorder := httptest.NewRecorder()
	NewHandler(nil, nil, CorsPolicy{}).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/v2/feed/groups", nil))
	if recorder.Code != http.StatusUnauthorized || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("group feed status %d: %s", recorder.Code, recorder.Body)
	}
}
