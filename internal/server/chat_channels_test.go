package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type chatChannelFixture struct{ *memorySessions }

func (*chatChannelFixture) ListChatChannels(_ context.Context, user, group int64) ([]chatChannel, error) {
	if user != 42 || group != 7 {
		return nil, errChatGroupForbidden
	}
	return []chatChannel{{ID: 8, GroupID: 7, Type: "text", UnreadCount: 2}}, nil
}

func TestChatChannelListRoute(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		id, token string
		status    int
	}{
		{"7", "", 401}, {"9007199254740992", tokens["access-hs256"], 400},
		{"9", tokens["access-hs256"], 403}, {"7", tokens["access-hs256"], 200},
	} {
		req := httptest.NewRequest("GET", "/api/v2/chat/groups/"+tc.id+"/channels?user_id=9", nil)
		if tc.token != "" {
			req.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("status=%d body=%s", w.Code, w.Body)
		}
		if tc.status == 200 && (!strings.Contains(w.Body.String(), `"unread_count":2`) || !strings.Contains(w.Body.String(), `"last_message":null`)) {
			t.Fatal(w.Body.String())
		}
	}
}

func (*chatChannelFixture) ListChatMembers(_ context.Context, user, group int64, _ StorageURLPolicy) ([]chatMember, error) {
	if user != 42 || group != 7 {
		return nil, errChatGroupForbidden
	}
	return []chatMember{{ID: 9, OnlineStatus: "hidden", Status: "muted"}}, nil
}

func TestChatMembersRequiresSessionAndSafeID(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		id, token string
		status    int
	}{
		{"7", "", 401}, {"9007199254740992", tokens["access-hs256"], 400},
		{"9", tokens["access-hs256"], 403}, {"7", tokens["access-hs256"], 200},
	} {
		req := httptest.NewRequest("GET", "/api/v2/chat/groups/"+tc.id+"/members", nil)
		if tc.token != "" {
			req.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("id=%s status=%d body=%s", tc.id, w.Code, w.Body)
		}
		if tc.status == 200 && (!strings.Contains(w.Body.String(), `"online_status":"hidden"`) ||
			!strings.Contains(w.Body.String(), `"last_seen_at":null`)) {
			t.Error(w.Body.String())
		}
	}
}

func TestChatMessageHistoryRejectsUnsafeChannelID(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	req := httptest.NewRequest("GET", "/api/v2/chat/channels/9007199254740992/messages", nil)
	req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	app.ServeHTTP(w, req)
	if w.Code != 400 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
}

func TestChatMessageMutationRejectsInvalidInput(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	for _, tc := range []struct{ method, path, body string }{
		{"PATCH", "8", `{"content":" "}`},
		{"DELETE", "9007199254740992", ""},
		{"PUT", "8/pin-status", `[]`},
		{"POST", "8/reactions", `{"emoji":" "}`},
		{"DELETE", "8/reactions", `{"emoji":7}`},
	} {
		req := httptest.NewRequest(tc.method, "/api/v2/chat/messages/"+tc.path, strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != 400 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s: status=%d body=%s", tc.path, w.Code, w.Body)
		}
	}
}

func TestChatMessageSendRejectsEmptyPayload(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	req := httptest.NewRequest("POST", "/api/v2/chat/channels/7/messages", strings.NewReader(`{"content":"  "}`))
	req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	app.ServeHTTP(w, req)
	if w.Code != 400 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
}

func (*chatChannelFixture) ListChatMessages(_ context.Context, user, channel int64, page SessionPage, search chatMessageSearch, _ StorageURLPolicy) ([]chatMessage, int64, error) {
	if user != 42 || channel != 7 {
		return nil, 0, errChatGroupForbidden
	}
	if page.Page != 2 || page.PageSize != 3 || search.keyword != "Hello" {
		return nil, 0, errors.New("unexpected search or pagination")
	}
	return []chatMessage{{ID: 8, ChannelID: channel, Media: []PostMedia{}, Reactions: []chatReaction{}}}, 10, nil
}

func TestChatMessageHistoryRoute(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		id, token, want string
		status          int
	}{
		{"7", "", `"code":40101`, 401},
		{"9", tokens["access-hs256"], `"code":40301`, 403},
		{"7", tokens["access-hs256"], `"has_next":true`, 200},
	} {
		req := httptest.NewRequest("GET", "/api/v2/chat/channels/"+tc.id+"/messages?page=2&page_size=3&q=+Hello+", nil)
		if tc.token != "" {
			req.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" ||
			!strings.Contains(w.Body.String(), tc.want) {
			t.Errorf("%s: %d %s", tc.id, w.Code, w.Body)
		}
	}
}

func TestChatChannelStatusRejectsInvalidInput(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	for _, tc := range []struct{ endpoint, body string }{
		{"read-status", `{"last_read_message_id":1.5}`},
		{"read-status", `{"last_read_message_id":9007199254740992}`},
		{"mute-status", `[]`},
	} {
		req := httptest.NewRequest("PUT", "/api/v2/chat/channels/7/"+tc.endpoint, strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != 400 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s: %d %s", tc.endpoint, w.Code, w.Body)
		}
	}
}

func (*chatChannelFixture) SetChatChannelRead(_ context.Context, user, channel, target int64) (chatChannelRead, error) {
	if user != 42 || channel != 7 {
		return chatChannelRead{}, errChatGroupForbidden
	}
	if target == 9 {
		return chatChannelRead{}, errChatReadMessage
	}
	cursor := int64(12)
	return chatChannelRead{ChannelID: channel, LastRead: &cursor, Unread: 2}, nil
}

func (*chatChannelFixture) SetChatChannelMute(_ context.Context, user, channel int64, _ bool) error {
	if user != 42 || channel != 7 {
		return errChatGroupForbidden
	}
	return nil
}

func TestChatChannelStatusRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		path, body, contains string
		status               int
	}{
		{"7/read-status", "", `"last_read_message_id":12`, 200},
		{"7/read-status", `{"last_read_message_id":8}`, `"unread_count":2`, 200},
		{"7/read-status", `{"last_read_message_id":9}`, `"code":40001`, 400},
		{"7/mute-status", `{"is_muted":false}`, `"is_muted":false`, 200},
		{"7/mute-status", `{"is_muted":true}`, `"is_muted":true`, 200},
		{"9/mute-status", `{"is_muted":true}`, `"code":40301`, 403},
	} {
		req := httptest.NewRequest("PUT", "/api/v2/chat/channels/"+tc.path, strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" ||
			!strings.Contains(w.Body.String(), tc.contains) {
			t.Errorf("%s: %d %s", tc.path, w.Code, w.Body)
		}
	}
}

func (*chatChannelFixture) WriteChatChannel(_ context.Context, user, id int64, change chatChannelChange) (chatChannel, error) {
	if user != 42 || id != 7 {
		return chatChannel{}, errChatGroupForbidden
	}
	if change.remove {
		return chatChannel{}, nil
	}
	if change.name == nil || *change.name != "技术交流" {
		return chatChannel{}, errors.New("wrong channel name")
	}
	if change.create && (change.kind != "text" || change.category == nil || *change.category != "文字频道") {
		return chatChannel{}, errors.New("wrong defaults")
	}
	return chatChannel{ID: 8, GroupID: 7, Name: *change.name, Type: "text", CanManage: true}, nil
}

func TestChatChannelWriteRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatChannelFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		method, path, body, message string
		status                      int
	}{
		{"POST", "/groups/7/channels", `{"name":" 技术交流 "}`, "chat channel created", 200},
		{"PATCH", "/channels/7", `{"name":"技术交流"}`, "chat channel updated", 200},
		{"DELETE", "/channels/7", "", "chat channel deleted", 200},
		{"POST", "/groups/7/channels", `{"name":"x","type":"bad"}`, "", 400},
		{"PATCH", "/channels/7", `{"name":" "}`, "", 400},
		{"POST", "/groups/7/channels", `{"name":"x"} {}`, "", 400},
		{"DELETE", "/channels/9", "", "", 403},
		{"DELETE", "/channels/9007199254740992", "", "", 400},
	} {
		req := httptest.NewRequest(tc.method, "/api/v2/chat"+tc.path, strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" ||
			tc.message != "" && !strings.Contains(w.Body.String(), tc.message) {
			t.Errorf("%s %s: status=%d body=%s", tc.method, tc.path, w.Code, w.Body)
		}
		if tc.method == "DELETE" && tc.status == 200 && !strings.Contains(w.Body.String(), `"data":null`) {
			t.Error(w.Body.String())
		}
	}
}

type chatChannelConnector struct {
	state          driverState
	writes, counts int
	raced, fail    bool
	manage         bool
	failReadback   bool
	locked         bool
	statusDenied   bool
	statusTarget   driver.Value
	statusCurrent  driver.Value
	historyEnrich  bool
	historyFail    bool
	historyQueries []listQueryCall
	sendStatus     string
	accountMuted   bool
	sendFail       bool
	sendMediaKey   string
	privateDenied  bool
	directLinked   bool
	privateChecks  int
	mutationAuthor int64
	mutationFail   bool
}
type chatChannelConn struct {
	*testConn
	fixture *chatChannelConnector
}

func (*chatChannelConnector) Driver() driver.Driver { return testDriver{} }
func (f *chatChannelConnector) Connect(context.Context) (driver.Conn, error) {
	return &chatChannelConn{&testConn{&f.state}, f}, nil
}
func (c *chatChannelConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	var result []driver.Value
	for _, statement := range []string{chatMessageCountSQL, chatMessagePageSQL} {
		if strings.HasPrefix(query, statement) {
			c.fixture.historyQueries = append(c.fixture.historyQueries, listQueryCall{query, args})
			query = statement
			break
		}
	}
	switch query {
	case chatMemberListSQL:
		if len(args) != 2 || args[1].Name != "user_id" || args[1].Value != int64(42) {
			return nil, errors.New("missing viewer scope")
		}
		switch args[0].Value {
		case int64(7):
			result = []driver.Value{int64(8), "member", "nickname", nil, "member", "muted", "hidden", time.Now()}
		case int64(8):
			result = make([]driver.Value, 8)
		default:
			return &alertRows{values: make([]driver.Value, 8), done: true}, nil
		}
	case chatMutationChannelSQL:
		result = []driver.Value{int64(7)}
	case chatMutationTargetSQL:
		if !c.fixture.locked {
			return nil, errors.New("message locked before channel access")
		}
		result = []driver.Value{c.fixture.mutationAuthor, "text"}
	case publishPolicy.SQL["lock"]:
		result = []driver.Value{int64(42)}
	case publishPolicy.SQL["allowed"]:
		allowed := int64(1)
		if c.fixture.accountMuted {
			allowed = 0
		}
		result = []driver.Value{allowed}
	case chatSendAccessSQL:
		result = []driver.Value{int64(6), "text", c.fixture.sendStatus, int64(1)}
	case chatSendReplySQL:
		result = []driver.Value{int64(77)}
	case chatSendMediaSQL:
		result = []driver.Value{int64(77), c.fixture.sendMediaKey}
	case directExtrasContract.SQL["asset_is_linked"]:
		if c.fixture.directLinked {
			return &alertRows{values: []driver.Value{int64(1)}}, nil
		}
		return emptyRows{&c.fixture.state}, nil
	case privateMediaBinding.Chat:
		c.fixture.privateChecks++
		if len(args) != 1 || args[0].Name != "media_id" || args[0].Value != int64(77) {
			return nil, errors.New("invalid private media authorization binding")
		}
		if c.fixture.privateDenied {
			return emptyRows{&c.fixture.state}, nil
		}
		result = []driver.Value{int64(1)}
	case "SELECT seq_chat_message_id.NEXTVAL FROM dual":
		result = []driver.Value{int64(8)}
	case chatMessageAccessSQL:
		result = []driver.Value{int64(1)}
	case chatMessageCountSQL:
		result = []driver.Value{int64(2)}
	case chatMessagePageSQL, chatMessageByIDSQL:
		result = []driver.Value{int64(8), int64(7), int64(6), int64(42), "text", "hello",
			int64(0), int64(0), nil, nil, nil, nil, "reader", nil, nil, nil, nil, nil,
			int64(0), int64(0), int64(0), int64(0), int64(0), "self", nil, "hidden", "hidden"}
	case readChatChannelSQL:
		result = []driver.Value{int64(1)}
	case chatChannelGroupSQL:
		result = []driver.Value{int64(7)}
	case readChatChannelSQL + " FOR UPDATE OF gm.role":
		if !c.fixture.locked {
			return nil, errors.New("missing group lock")
		}
		if c.fixture.statusDenied {
			return &alertRows{values: []driver.Value{int64(1)}, done: true}, nil
		}
		result = []driver.Value{int64(1)}
	case chatReadTargetSQL:
		result = []driver.Value{c.fixture.statusTarget}
	case chatReadResultSQL:
		if c.fixture.failReadback {
			return nil, errors.New("readback failed")
		}
		result = []driver.Value{c.fixture.statusCurrent, int64(2)}
	case chatGroupMembershipSQL:
		result = []driver.Value{int64(0)}
	case countChatChannelsSQL:
		c.fixture.counts++
		count := int64(0)
		if c.fixture.raced && c.fixture.counts == 2 {
			count = 2
		}
		result = []driver.Value{count}
	case lockChatGroupSQL:
		c.fixture.locked = true
		result = []driver.Value{int64(9)}
	case chatGroupMembershipSQL + " FOR UPDATE OF gm.role":
		if !c.fixture.locked {
			return nil, errors.New("membership locked before group")
		}
		manage := int64(0)
		if c.fixture.manage {
			manage = 1
		}
		result = []driver.Value{manage}
	case "SELECT seq_chat_channel_id.NEXTVAL FROM dual":
		result = []driver.Value{int64(8)}
	case chatChannelByIDSQL:
		if c.fixture.failReadback {
			return nil, errors.New("readback failed")
		}
		if c.fixture.writes != 1 || len(args) != 3 || args[2].Value != int64(8) {
			return nil, errors.New("incorrect readback")
		}
		result = []driver.Value{int64(8), int64(7), "技术交流", "text", "文字频道", int64(10), int64(0), nil, nil,
			int64(0), int64(1), int64(0), nil, nil, nil, nil}
	case listChatChannelsSQL:
		if len(args) != 2 || args[0].Value != int64(42) || args[1].Value != int64(7) {
			return nil, errors.New("wrong group scope")
		}
		result = []driver.Value{int64(8), int64(7), "综合讨论", "text", nil, int64(20), int64(0), nil, nil,
			int64(1), int64(0), int64(2), nil, nil, nil, nil}
	default:
		switch {
		case c.fixture.historyEnrich && strings.Contains(query, "FROM n_chat_message_media"):
			if c.fixture.historyFail {
				return nil, errors.New("attachment query failed")
			}
			result = []driver.Value{int64(8), int64(77), "image", "asset.png", "/storage/asset.png",
				int64(1024), "image/png", nil, nil, nil, nil, nil, nil, "ready", nil}
			if c.fixture.sendMediaKey == "private/chat/files/42/a.png" {
				result[4] = "/api/v2/media/77/content"
			}
		case c.fixture.historyEnrich && strings.Contains(query, "FROM n_chat_message_reactions"):
			result = []driver.Value{int64(8), "🙂", int64(3), int64(1)}
		default:
			return nil, errors.New("unexpected query")
		}
	}
	return &alertRows{values: result}, nil
}
func (c *chatChannelConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.fixture.writes++
	switch query {
	case chatReactionAddSQL, chatReactionRemoveSQL:
		if !c.fixture.locked || len(args) != 3 || args[0].Value != int64(8) ||
			args[1].Value != int64(42) || args[2].Value != "👍" {
			return nil, errors.New("invalid reaction scope")
		}
		return driver.RowsAffected(0), nil
	case chatEditSQL, chatPinSQL, chatDeleteSQL, chatDeleteSummarySQL:
		if !c.fixture.locked || (c.fixture.mutationFail && query == chatDeleteSummarySQL) {
			return nil, errors.New("mutation write failed")
		}
		return driver.RowsAffected(1), nil
	}
	if query == chatSendInsertSQL || query == chatSendAttachSQL || query == chatSendSummarySQL {
		if !c.fixture.locked || (c.fixture.sendFail && query == chatSendAttachSQL) {
			return nil, errors.New("send write failed")
		}
		return driver.RowsAffected(1), nil
	}
	if query == mergeChatReadSQL || query == mergeChatMuteSQL || query == deleteChatMuteSQL {
		if !c.fixture.locked || args[0].Value != int64(7) || args[1].Value != int64(42) {
			return nil, errors.New("wrong channel status scope")
		}
		return driver.RowsAffected(1), nil
	}
	if query == insertChatChannelSQL {
		if !c.fixture.locked || !c.fixture.manage || len(args) != 7 || args[0].Value != int64(8) {
			return nil, errors.New("unauthorized insert")
		}
		return driver.RowsAffected(1), nil
	}
	if query != insertDefaultChatChannelSQL || args[5].Value != int64(9) || c.fixture.fail && c.fixture.writes == 2 {
		return nil, errors.New("insert failed")
	}
	return driver.RowsAffected(1), nil
}

func TestChatMembersRepositoryDistinguishesDeniedAndEmpty(t *testing.T) {
	db := sql.OpenDB(&chatChannelConnector{})
	defer db.Close()
	repo := OracleSessions{DB: db}
	members, err := repo.ListChatMembers(context.Background(), 42, 7, StorageURLPolicy{})
	if err != nil || len(members) != 1 || members[0].LastSeenAt != nil ||
		members[0].OnlineStatus != "hidden" || members[0].DisplayName != "nickname" {
		t.Fatalf("members=%+v err=%v", members, err)
	}
	members, err = repo.ListChatMembers(context.Background(), 42, 8, StorageURLPolicy{})
	if err != nil || members == nil || len(members) != 0 {
		t.Fatalf("empty=%+v err=%v", members, err)
	}
	if _, err := repo.ListChatMembers(context.Background(), 42, 9, StorageURLPolicy{}); !errors.Is(err, errChatGroupForbidden) {
		t.Fatal(err)
	}
}

func TestChatMessageMutationCommitsOnlyAfterSummary(t *testing.T) {
	for _, tc := range []struct {
		kind, status string
		author       int64
		fail         bool
		want         error
		writes       int
	}{
		{"react", "muted", 9, false, nil, 1},
		{"unreact", "active", 9, false, nil, 1},
		{"delete", "active", 42, false, nil, 2},
		{"delete", "active", 42, true, errSessionStore, 2},
		{"edit", "active", 9, false, errChatMutationForbidden, 0},
		{"edit", "muted", 42, false, errChatMutationForbidden, 0},
		{"edit", "active", 42, false, nil, 1},
		{"edit", "active", 42, false, errPublishForbidden, 0},
		{"pin", "muted", 9, false, nil, 1},
	} {
		f := &chatChannelConnector{historyEnrich: true, sendStatus: tc.status, mutationAuthor: tc.author, mutationFail: tc.fail, accountMuted: errors.Is(tc.want, errPublishForbidden)}
		db := sql.OpenDB(f)
		result, err := (OracleSessions{DB: db}).MutateChatMessage(context.Background(), 42, 8,
			chatMutation{kind: tc.kind, content: "edited", pinned: true, emoji: "👍"}, StorageURLPolicy{})
		db.Close()
		if !errors.Is(err, tc.want) || f.writes != tc.writes {
			t.Fatalf("%s status=%s writes=%d err=%v", tc.kind, tc.status, f.writes, err)
		}
		if err != nil {
			if f.state.commits != 0 || f.state.rollbacks != 1 {
				t.Fatal("failed mutation must roll back")
			}
		} else if f.state.commits != 1 || result.channel != 7 {
			t.Fatalf("result=%+v commits=%d", result, f.state.commits)
		}
	}
}

func TestChatMessageSendTransaction(t *testing.T) {
	reply := int64(77)
	input := chatSendInput{content: "hello", reply: &reply, media: []int64{77}}
	for _, tc := range []struct {
		status string
		fail   bool
		want   error
		writes int
	}{
		{"active", false, nil, 3},
		{"active", true, errSessionStore, 2},
		{"muted", false, errChatCannotSpeak, 0},
		{"active", false, errPublishForbidden, 0},
	} {
		f := &chatChannelConnector{historyEnrich: true, sendStatus: tc.status, sendFail: tc.fail, accountMuted: errors.Is(tc.want, errPublishForbidden)}
		db := sql.OpenDB(f)
		message, err := (OracleSessions{DB: db}).SendChatMessage(context.Background(), 42, 7, input, StorageURLPolicy{})
		db.Close()
		if !errors.Is(err, tc.want) || f.writes != tc.writes {
			t.Fatalf("status=%s writes=%d err=%v", tc.status, f.writes, err)
		}
		if err != nil {
			if f.state.rollbacks != 1 || f.state.commits != 0 {
				t.Fatal("failed operation must roll back")
			}
		} else if f.state.commits != 1 || message.ID != 8 || len(message.Media) != 1 {
			t.Fatalf("message=%+v commits=%d", message, f.state.commits)
		}
	}
}

func TestChatMessageHistoryLoadsDetailsBeforeAdvancingCursor(t *testing.T) {
	for _, tc := range []struct {
		page   float64
		search string
		fail   bool
		writes int
	}{
		{1, "", false, 1}, {2, "", false, 0}, {1, "", true, 0}, {1, "hello", false, 0},
	} {
		f := &chatChannelConnector{historyEnrich: true, historyFail: tc.fail}
		db := sql.OpenDB(f)
		messages, total, err := (OracleSessions{DB: db}).ListChatMessages(
			context.Background(), 42, 7, SessionPage{Page: tc.page, Start: 1, End: 20}, chatMessageSearch{keyword: tc.search}, StorageURLPolicy{})
		db.Close()
		if f.writes != tc.writes {
			t.Fatalf("page=%v writes=%d", tc.page, f.writes)
		}
		if tc.fail {
			if err == nil || f.state.rollbacks != 1 || f.state.commits != 0 {
				t.Fatalf("enrichment failure did not roll back: %v", err)
			}
			continue
		}
		if err != nil || total != 2 || f.state.commits != 1 || len(messages) != 1 {
			t.Fatalf("history=%+v total=%d err=%v", messages, total, err)
		}
		message := messages[0]
		if message.Reply != nil || !message.CanPin || !message.CanDelete || len(message.Media) != 1 ||
			message.Media[0].MediaID != 77 || len(message.Reactions) != 1 || !message.Reactions[0].Reacted {
			t.Fatalf("unexpected message: %+v", message)
		}
	}
}

func TestChatChannelReadReturnsCommittedCursor(t *testing.T) {
	for _, tc := range []struct {
		name           string
		target         int64
		candidate      driver.Value
		denied, failed bool
		want           error
		writes         int
	}{
		{"older", 8, int64(8), false, false, nil, 1},
		{"revoked", 8, int64(8), true, false, errChatGroupForbidden, 0},
		{"missing", 8, nil, false, false, errChatReadMessage, 0},
		{"readback", 8, int64(8), false, true, errSessionStore, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &chatChannelConnector{statusTarget: tc.candidate, statusCurrent: int64(12),
				statusDenied: tc.denied, failReadback: tc.failed}
			db := sql.OpenDB(f)
			defer db.Close()
			out, err := (OracleSessions{DB: db}).SetChatChannelRead(context.Background(), 42, 7, tc.target)
			if !errors.Is(err, tc.want) || f.writes != tc.writes {
				t.Fatalf("writes=%d err=%v", f.writes, err)
			}
			if err != nil {
				if f.state.rollbacks != 1 || f.state.commits != 0 {
					t.Fatal("failed operation must roll back")
				}
			} else if f.state.commits != 1 || out.LastRead == nil || *out.LastRead != 12 || out.Unread != 2 {
				t.Fatalf("out=%+v commits=%d", out, f.state.commits)
			}
		})
	}
}

func TestChatChannelCreateCommitsOnlyAfterReadback(t *testing.T) {
	name, category, private := "技术交流", "文字频道", false
	change := chatChannelChange{create: true, name: &name, category: &category, private: &private, kind: "text"}
	for _, tc := range []struct {
		manage, failReadback bool
		want                 error
		writes, commits      int
	}{
		{true, false, nil, 1, 1},
		{true, true, errSessionStore, 1, 0},
		{false, false, errChatGroupForbidden, 0, 0},
	} {
		f := &chatChannelConnector{manage: tc.manage, failReadback: tc.failReadback}
		db := sql.OpenDB(f)
		channel, err := (OracleSessions{DB: db}).WriteChatChannel(context.Background(), 42, 7, change)
		db.Close()
		if !errors.Is(err, tc.want) || f.writes != tc.writes || f.state.commits != tc.commits ||
			f.state.rollbacks != 1-tc.commits || err == nil && channel.ID != 8 {
			t.Fatalf("manage=%v failReadback=%v writes=%d commits=%d rollbacks=%d channel=%+v err=%v",
				tc.manage, tc.failReadback, f.writes, f.state.commits, f.state.rollbacks, channel, err)
		}
	}
}

func TestChatChannelDefaultsAreAtomicAndRecountAfterLock(t *testing.T) {
	for _, tc := range []struct{ raced, fail bool }{{}, {raced: true}, {fail: true}} {
		f := &chatChannelConnector{raced: tc.raced, fail: tc.fail}
		db := sql.OpenDB(f)
		channels, err := (OracleSessions{DB: db}).ListChatChannels(context.Background(), 42, 7)
		db.Close()
		if tc.fail {
			if err == nil || f.state.commits != 0 || f.state.rollbacks != 1 {
				t.Fatal("partial initialization escaped rollback")
			}
			continue
		}
		if err != nil || len(channels) != 1 || !channels[0].Muted || channels[0].CanManage || channels[0].Category != "文字频道" || f.state.commits != 1 || f.counts != 2 {
			t.Fatal(channels, err, f)
		}
		if tc.raced && f.writes != 0 || !tc.raced && f.writes != 2 {
			t.Fatal("incorrect default writes", f.writes)
		}
	}
}
