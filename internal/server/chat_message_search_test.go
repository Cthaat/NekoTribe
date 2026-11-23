package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

func TestChatSearchRejectsInvalidFilters(t *testing.T) {
	codec, tokens := fixture(t)
	for _, backend := range []struct {
		path string
		repo SessionRepository
	}{
		{"/api/v2/chat/channels/7/messages", &chatChannelFixture{store()}},
		{"/api/v2/chat/direct-conversations/7/messages", &directHistoryFixture{memorySessions: store()}},
	} {
		app := NewHandler(codec, backend.repo, CorsPolicy{})
		for _, query := range []string{
			"sender_id=0", "sender_id=", "sender_id=9007199254740992", "sender_id=7&sender_id=9",
			"q=a&q=b", "q=%ff", "q=" + strings.Repeat("%E7%8C%AB", 134),
			"start_at=2026-11-22", "end_at=2026-02-29T00:00:00Z", "end_at=2026-11-22T24:00:00Z",
			"start_at=2026-11-22T00:00:00.1231Z&end_at=2026-11-22T00:00:00.1239Z",
			"start_at=2026-11-23T00:00:00Z&end_at=2026-11-22T00:00:00Z",
		} {
			req := httptest.NewRequest("GET", backend.path+"?page=2&page_size=3&"+query, nil)
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			app.ServeHTTP(w, req)
			if w.Code != 400 || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Errorf("%s?%s: got %d %s", backend.path, query, w.Code, w.Body)
			}
		}
	}
}

type chatSearchHTTPRepository struct {
	OracleSessions
	sessions *memorySessions
}

func (s chatSearchHTTPRepository) Touch(ctx context.Context, claims auth.Claims) (int64, error) {
	return s.sessions.Touch(ctx, claims)
}

func TestChatSearchUsesScopedBindsAndSkipsReadUpdates(t *testing.T) {
	codec, tokens := fixture(t)
	query := url.Values{
		"q":         {"  HeLLo%_  "},
		"sender_id": {"42"},
		"start_at":  {"2026-11-22T08:01:02.123456789012+08:00"},
		"end_at":    {"2026-11-22T00:02:03.456789Z"},
	}.Encode()
	check := func(path string, connector driver.Connector, want int) {
		t.Helper()
		db := sql.OpenDB(connector)
		defer db.Close()
		repo := chatSearchHTTPRepository{OracleSessions{DB: db}, store()}
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		NewHandler(codec, repo, CorsPolicy{}).ServeHTTP(w, req)
		if w.Code != want || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body)
		}
	}
	assertQueries := func(t *testing.T, actual []listQueryCall, alias, senderColumn string) {
		t.Helper()
		if len(actual) != 2 {
			t.Fatalf("wanted count and page statements, got %d", len(actual))
		}
		for _, call := range actual {
			for _, fragment := range []string{
				"AND INSTR(LOWER(" + alias + ".content), LOWER(:search_keyword)) > 0",
				"AND " + alias + "." + senderColumn + " = :search_sender",
				"AND " + alias + ".created_at >= CAST((TO_TIMESTAMP_TZ(:search_start,",
				"AND " + alias + ".created_at < CAST((TO_TIMESTAMP_TZ(:search_end,",
			} {
				if !strings.Contains(call.sql, fragment) {
					t.Errorf("SQL missing %s", fragment)
				}
			}
			if strings.Contains(call.sql, "HeLLo") || directFixtureBind(call.args, "search_keyword") != "HeLLo%_" ||
				directFixtureBind(call.args, "search_sender") != int64(42) ||
				directFixtureBind(call.args, "search_start") != "2026-11-22T00:01:02.123+00:00" ||
				directFixtureBind(call.args, "search_end") != "2026-11-22T00:02:03.456+00:00" {
				t.Fatalf("unexpected search bindings: %v", call.args)
			}
		}
		if !strings.Contains(actual[1].sql, "ORDER BY "+alias+".created_at DESC,"+alias+".message_id DESC") ||
			!strings.HasSuffix(actual[1].sql, "ORDER BY created_at ASC,message_id ASC") {
			t.Fatalf("page lost history order: %s", actual[1].sql)
		}
	}

	channelPath := "/api/v2/chat/channels/7/messages"
	channel := &chatChannelConnector{historyEnrich: true}
	check(channelPath+"?"+query, channel, 200)
	assertQueries(t, channel.historyQueries, "m", "author_id")
	if channel.writes != 0 {
		t.Fatal("filtered channel history advanced the read cursor")
	}
	deniedChannel := &chatChannelConnector{statusDenied: true}
	check(channelPath+"?"+query, deniedChannel, 403)
	if len(deniedChannel.historyQueries) != 0 || deniedChannel.writes != 0 {
		t.Fatal("forbidden channel reached search or write")
	}

	directPath := "/api/v2/chat/direct-conversations/7/messages"
	direct := &directHistoryConnector{}
	check(directPath+"?"+query, direct, 200)
	assertQueries(t, direct.historyQueries, "dm", "sender_id")
	if direct.marked != 0 {
		t.Fatal("filtered direct history advanced the default read cursor")
	}
	deniedDirect := &directHistoryConnector{denied: true}
	check(directPath+"?"+query, deniedDirect, 403)
	if len(deniedDirect.historyQueries) != 0 || deniedDirect.marked != 0 {
		t.Fatal("nonparticipant reached search or write")
	}

	blankChannel := &chatChannelConnector{historyEnrich: true}
	blankDirect := &directHistoryConnector{}
	check(channelPath+"?q=%E3%80%80", blankChannel, 200)
	check(directPath+"?q=+", blankDirect, 200)
	if blankChannel.writes != 1 || blankDirect.marked != 11 {
		t.Fatal("whitespace-only keywords affected normal history reads")
	}
}
