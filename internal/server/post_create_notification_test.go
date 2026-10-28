package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"strings"
	"testing"
)

type postCreateNoticeFixture struct {
	*memorySessions
	calls           []string
	inputs          []notificationInput
	author          int64
	resolve         map[float64]int64
	fail            string
	push, skipStore bool
	missing         bool
}

func (s *postCreateNoticeFixture) step(label string) error {
	s.calls = append(s.calls, label)
	if s.fail == label {
		return errSessionStore
	}
	return nil
}
func (s *postCreateNoticeFixture) PostCreateActorName(_ context.Context, actor int64) (string, error) {
	return "viewer", s.step(fmt.Sprintf("actor:%d", actor))
}
func (s *postCreateNoticeFixture) PostCreateSourceAuthor(_ context.Context, post int64) (int64, error) {
	return s.author, s.step(fmt.Sprintf("author:%d", post))
}
func (s *postCreateNoticeFixture) PostCreateExcerpt(_ context.Context, post int64) (json.RawMessage, error) {
	return json.RawMessage(`"source text"`), s.step(fmt.Sprintf("excerpt:%d", post))
}
func (s *postCreateNoticeFixture) ResolvePostMentionRecipient(_ context.Context, user float64) (int64, error) {
	return s.resolve[user], s.step(fmt.Sprintf("resolve:%g", user))
}
func (s *postCreateNoticeFixture) StorePostCreateNotification(_ context.Context, input notificationInput) (*notificationStored, error) {
	if err := s.step(fmt.Sprintf("store:%d:%s", input.UserID, input.Type)); err != nil {
		return nil, err
	}
	if s.skipStore || input.UserID <= 0 || input.ActorID != nil && input.UserID == *input.ActorID {
		return nil, nil
	}
	s.inputs = append(s.inputs, input)
	return &notificationStored{ID: int64(len(s.inputs)), PushEnabled: s.push}, nil
}
func (s *postCreateNoticeFixture) NotificationByID(_ context.Context, user, id int64) (NotificationItem, bool, error) {
	if err := s.step(fmt.Sprintf("lookup:%d:%d", user, id)); err != nil {
		return NotificationItem{}, false, err
	}
	input := s.inputs[id-1]
	return NotificationItem{ID: id, ActorID: input.ActorID, Type: input.Type, metadataRaw: json.RawMessage(input.MetadataJSON)}, !s.missing, nil
}
func (s *postCreateNoticeFixture) PublicProfile(_ context.Context, viewer, actor int64) (PublicUser, bool, error) {
	return PublicUser{UserID: actor, Username: "viewer"}, true, s.step(fmt.Sprintf("profile:%d:%d", viewer, actor))
}

type postCreateNoticePublisher struct {
	users []int64
	types []string
	fail  bool
}

func (p *postCreateNoticePublisher) Publish(_ context.Context, user int64, event string, payload map[string]interface{}) error {
	if event != "notification_created" {
		return errors.New("unexpected event")
	}
	p.users = append(p.users, user)
	p.types = append(p.types, fmt.Sprint(payload["notification_type"]))
	if p.fail {
		return errors.New("redis unavailable")
	}
	return nil
}

func TestNotifyPostCreatedSourceMetadataAndDeliveryType(t *testing.T) {
	source := int64(10)
	for _, tc := range []struct {
		kind, notificationType, title, message, excerpt string
		input                                           PostCreateInput
	}{
		{"reply", "comment", "回复了你的推文", "你的推文收到了一条新回复。", "reply_excerpt", PostCreateInput{ReplyToPostID: &source}},
		{"repost", "retweet", "转发了你的推文", "你的推文被转发了。", "retweet_excerpt", PostCreateInput{RepostOfPostID: &source}},
		{"quote", "retweet", "引用了你的推文", "你的推文被引用了。", "quote_excerpt", PostCreateInput{QuotedPostID: &source}},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			s := &postCreateNoticeFixture{memorySessions: store(), author: 7, push: true}
			publisher := &postCreateNoticePublisher{}
			tc.input.Content = " \t" + strings.Repeat("x", 159) + "😀after\n"
			err := notifyPostCreated(context.Background(), s, s, RefreshConfig{NotificationPublisher: publisher}, 42, 100, tc.input)
			if err != nil || len(s.inputs) != 1 || !reflect.DeepEqual(publisher.types, []string{tc.notificationType}) {
				t.Fatalf("inputs=%+v events=%v err=%v", s.inputs, publisher.types, err)
			}
			n := s.inputs[0]
			if n.UserID != 7 || n.ActorID == nil || *n.ActorID != 42 || n.Type != tc.notificationType || n.Title != "viewer "+tc.title || n.Message != tc.message || n.Priority != "normal" || n.ResourceType == nil || *n.ResourceType != "post" || n.ResourceID == nil || *n.ResourceID != 100 {
				t.Fatal(n)
			}
			var meta map[string]json.RawMessage
			if json.Unmarshal([]byte(n.MetadataJSON), &meta) != nil || len(meta) != 6 || string(meta["source_post_id"]) != "10" || string(meta["target_post_id"]) != "10" || string(meta["action_post_id"]) != "100" || string(meta["post_excerpt"]) != `"source text"` || string(meta["event"]) != `"post_`+tc.kind+`"` || string(meta[tc.excerpt]) != `"`+strings.Repeat("x", 159)+`\ud83d..."` {
				t.Fatal(n.MetadataJSON)
			}
			want := []string{"actor:42", "author:10", "excerpt:10", "store:7:" + tc.notificationType, "lookup:7:1", "profile:7:42"}
			if !reflect.DeepEqual(s.calls, want) {
				t.Fatal(s.calls)
			}
		})
	}
}

func TestNotifyPostCreatedAlwaysReadsActorAndSkipsMissingSource(t *testing.T) {
	s := &postCreateNoticeFixture{memorySessions: store()}
	if err := notifyPostCreated(context.Background(), s, s, RefreshConfig{}, 42, 100, PostCreateInput{}); err != nil || !reflect.DeepEqual(s.calls, []string{"actor:42"}) {
		t.Fatal(err, s.calls)
	}
	s.calls = nil
	source := int64(10)
	if err := notifyPostCreated(context.Background(), s, s, RefreshConfig{}, 42, 100, PostCreateInput{ReplyToPostID: &source}); err != nil || !reflect.DeepEqual(s.calls, []string{"actor:42", "author:10"}) {
		t.Fatal(err, s.calls)
	}
	s.fail = "actor:42"
	if err := notifyPostCreated(context.Background(), s, s, RefreshConfig{}, 42, 100, PostCreateInput{}); !errors.Is(err, errSessionStore) {
		t.Fatal("actor lookup failure was swallowed", err)
	}
}

func TestNotifyPostCreatedMentionsPreserveNumberAndQueryOrder(t *testing.T) {
	s := &postCreateNoticeFixture{memorySessions: store(), resolve: map[float64]int64{7: 7, 42: 42}, push: true}
	publisher := &postCreateNoticePublisher{}
	input := PostCreateInput{Mentions: []float64{7.5, 7, 7.5, -1, 0, math.Copysign(0, -1), 42}}
	if err := notifyPostCreated(context.Background(), s, s, RefreshConfig{NotificationPublisher: publisher}, 42, 100, input); err != nil {
		t.Fatal(err)
	}
	if len(s.inputs) != 1 || s.inputs[0].UserID != 7 || s.inputs[0].Title != "viewer 提及了你" || s.inputs[0].Message != "你在一条推文中被提及。" || !reflect.DeepEqual(publisher.types, []string{"mention"}) {
		t.Fatal(s.inputs, publisher.types)
	}
	var meta map[string]any
	if json.Unmarshal([]byte(s.inputs[0].MetadataJSON), &meta) != nil || !reflect.DeepEqual(meta, map[string]any{"target_post_id": float64(100), "post_excerpt": "source text", "event": "post_mention"}) {
		t.Fatal(meta)
	}
	var resolved []string
	for i, call := range s.calls {
		if strings.HasPrefix(call, "resolve:") {
			if i == 0 || s.calls[i-1] != "excerpt:100" {
				t.Fatal("recipient resolved before excerpt", s.calls)
			}
			resolved = append(resolved, call)
		}
	}
	if !reflect.DeepEqual(resolved, []string{"resolve:7.5", "resolve:7"}) {
		t.Fatal(resolved)
	}
}

func TestNotifyPostCreatedSkippedMentionsStillReadExcerptWithoutResolving(t *testing.T) {
	for _, user := range []float64{0, -1, -7.5, 42} {
		t.Run(fmt.Sprint(user), func(t *testing.T) {
			s := &postCreateNoticeFixture{memorySessions: store(), resolve: map[float64]int64{7: 7}, fail: fmt.Sprintf("resolve:%g", user)}
			input := PostCreateInput{Mentions: []float64{user, 7}}
			if err := notifyPostCreated(context.Background(), s, s, RefreshConfig{}, 42, 100, input); err != nil {
				t.Fatal("skipped recipient performed a fallible lookup", err, s.calls)
			}
			want := []string{"actor:42", "excerpt:100", "excerpt:100", "resolve:7", "store:7:mention", "lookup:7:1", "profile:7:42"}
			if !reflect.DeepEqual(s.calls, want) || len(s.inputs) != 1 {
				t.Fatal(s.calls, s.inputs)
			}
			s.calls = nil
			s.fail = "excerpt:100"
			if err := notifyPostCreated(context.Background(), s, s, RefreshConfig{}, 42, 100, input); !errors.Is(err, errSessionStore) || !reflect.DeepEqual(s.calls, []string{"actor:42", "excerpt:100"}) {
				t.Fatal("excerpt error must precede recipient filtering", err, s.calls)
			}
		})
	}
}

func TestNotifyPostCreatedMentionsBeyondAttachmentLimit(t *testing.T) {
	s := &postCreateNoticeFixture{memorySessions: store(), resolve: make(map[float64]int64)}
	input := PostCreateInput{}
	for user := int64(1000); user < 1060; user++ {
		input.Mentions = append(input.Mentions, float64(user), float64(user))
		s.resolve[float64(user)] = user
	}
	if err := notifyPostCreated(context.Background(), s, s, RefreshConfig{}, 42, 100, input); err != nil || len(s.inputs) != 60 {
		t.Fatal(err, len(s.inputs))
	}
	for i, n := range s.inputs {
		if n.UserID != int64(1000+i) {
			t.Fatal("mention order changed", i, n.UserID)
		}
	}
}

func TestNotifyPostCreatedFailurePreservesEarlierNotifications(t *testing.T) {
	source := int64(10)
	for _, tc := range []struct {
		failure           string
		stored, published int
	}{
		{"author:10", 0, 0}, {"excerpt:10", 0, 0}, {"store:7:comment", 0, 0},
		{"lookup:7:1", 1, 0}, {"profile:7:42", 1, 0}, {"excerpt:100", 1, 1},
		{"resolve:8", 1, 1}, {"store:8:mention", 1, 1}, {"lookup:8:2", 2, 1},
	} {
		t.Run(tc.failure, func(t *testing.T) {
			s := &postCreateNoticeFixture{memorySessions: store(), author: 7, push: true, fail: tc.failure, resolve: map[float64]int64{8: 8, 9: 9}}
			publisher := &postCreateNoticePublisher{}
			input := PostCreateInput{ReplyToPostID: &source, Mentions: []float64{8, 9}}
			err := notifyPostCreated(context.Background(), s, s, RefreshConfig{NotificationPublisher: publisher}, 42, 100, input)
			if !errors.Is(err, errSessionStore) || len(s.inputs) != tc.stored || len(publisher.types) != tc.published || s.calls[len(s.calls)-1] != tc.failure {
				t.Fatal(err, s.inputs, publisher.types, s.calls)
			}
		})
	}
}

func TestNotifyPostCreatedDeliveryDegradesAfterStorage(t *testing.T) {
	source := int64(10)
	for _, mode := range []string{"redis failure", "nil publisher", "push disabled", "storage skipped", "notification missing"} {
		t.Run(mode, func(t *testing.T) {
			s := &postCreateNoticeFixture{memorySessions: store(), author: 7, push: mode != "push disabled", skipStore: mode == "storage skipped", missing: mode == "notification missing", resolve: map[float64]int64{8: 8}}
			publisher := &postCreateNoticePublisher{fail: mode == "redis failure"}
			config := RefreshConfig{NotificationPublisher: publisher}
			if mode == "nil publisher" {
				config.NotificationPublisher = nil
			}
			input := PostCreateInput{RepostOfPostID: &source, Mentions: []float64{8}}
			if err := notifyPostCreated(context.Background(), s, s, config, 42, 100, input); err != nil {
				t.Fatal(err)
			}
			wantStored, wantPublished := 2, 0
			if mode == "storage skipped" {
				wantStored = 0
			}
			if mode == "redis failure" {
				wantPublished = 2
			}
			if len(s.inputs) != wantStored || len(publisher.types) != wantPublished {
				t.Fatal(s.inputs, publisher.types)
			}
		})
	}
}

type postCreateNoticeSQLState struct {
	driverState
	value              driver.Value
	missing, failQuery bool
}
type postCreateNoticeConnector struct{ state *postCreateNoticeSQLState }
type postCreateNoticeConn struct {
	*testConn
	owner *postCreateNoticeSQLState
}

func (c postCreateNoticeConnector) Connect(context.Context) (driver.Conn, error) {
	return &postCreateNoticeConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c postCreateNoticeConnector) Driver() driver.Driver { return testDriver{} }
func (c *postCreateNoticeConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.owner.sql, c.owner.args = query, append([]driver.NamedValue(nil), args...)
	if c.owner.failQuery {
		return nil, errors.New("private database error")
	}
	if c.owner.missing {
		return emptyRows{&c.owner.driverState}, nil
	}
	return &alertRows{values: []driver.Value{c.owner.value}}, nil
}

func TestOraclePostCreateNoticeReadsAndSanitizesErrors(t *testing.T) {
	for _, tc := range []struct {
		name, query, bind, expected, fallback string
		value, binding                        driver.Value
		read                                  func(OracleSessions) (string, error)
	}{
		{"actor", "SELECT COALESCE(display_name,username) FROM n_users WHERE user_id=:user_id", "user_id", "viewer", "有人", "viewer", int64(42), func(s OracleSessions) (string, error) { return s.PostCreateActorName(context.Background(), 42) }},
		{"source", "SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0", "post_id", "7", "0", int64(7), int64(10), func(s OracleSessions) (string, error) {
			id, err := s.PostCreateSourceAuthor(context.Background(), 10)
			return fmt.Sprint(id), err
		}},
		{"excerpt", "SELECT DBMS_LOB.SUBSTR(content,4000,1) FROM n_posts WHERE post_id=:post_id AND is_deleted=0", "post_id", `"source text"`, "null", "\t source\ntext  ", int64(10), func(s OracleSessions) (string, error) {
			excerpt, err := s.PostCreateExcerpt(context.Background(), 10)
			return string(excerpt), err
		}},
		{"recipient", "SELECT user_id FROM n_users WHERE user_id=:user_id", "user_id", "7", "0", int64(7), float64(7), func(s OracleSessions) (string, error) {
			id, err := s.ResolvePostMentionRecipient(context.Background(), 7)
			return fmt.Sprint(id), err
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &postCreateNoticeSQLState{value: tc.value}
			db := sql.OpenDB(postCreateNoticeConnector{state})
			defer db.Close()
			repo := OracleSessions{db}
			got, err := tc.read(repo)
			if err != nil || got != tc.expected || state.sql != tc.query || len(state.args) != 1 || state.args[0].Name != tc.bind || state.args[0].Value != tc.binding {
				t.Fatal(got, err, state.sql, state.args)
			}
			state.value = nil
			got, err = tc.read(repo)
			if err != nil || got != tc.fallback {
				t.Fatal("null row", got, err)
			}
			state.missing = true
			got, err = tc.read(repo)
			if err != nil || got != tc.fallback {
				t.Fatal("missing row", got, err)
			}
			state.failQuery = true
			if _, err = tc.read(repo); !errors.Is(err, errSessionStore) {
				t.Fatal("unsanitized error", err)
			}
		})
	}
}

func TestOraclePostCreateMentionRecipientNeverTruncatesFraction(t *testing.T) {
	state := &postCreateNoticeSQLState{missing: true}
	db := sql.OpenDB(postCreateNoticeConnector{state})
	defer db.Close()
	for _, user := range []float64{7.5, -7.5, 0, 1e20} {
		got, err := (OracleSessions{db}).ResolvePostMentionRecipient(context.Background(), user)
		if err != nil || got != 0 || len(state.args) != 1 || state.args[0].Value != user {
			t.Fatal("recipient was narrowed before database lookup", user, got, err, state.args)
		}
	}
}

func TestOraclePostCreateStoreUsesNotificationPreferences(t *testing.T) {
	for _, tc := range []struct {
		name                      string
		actor, recipient, enabled int64
		inactive, stored          bool
	}{
		{"self", 42, 42, 1, false, false},
		{"disabled type", 42, 7, 0, false, false},
		{"inactive recipient", 42, 7, 1, true, false},
		{"push disabled still stored", 42, 7, 1, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &alertState{enabled: tc.enabled, inactive: tc.inactive}
			db := sql.OpenDB(alertConnector{state})
			defer db.Close()
			input := notificationInput{UserID: tc.recipient, ActorID: &tc.actor, Type: "mention", Priority: "normal"}
			got, err := (OracleSessions{db}).StorePostCreateNotification(context.Background(), input)
			if err != nil || (got != nil) != tc.stored || (state.commits == 1) != tc.stored || got != nil && got.PushEnabled {
				t.Fatal(got, err, state.commits)
			}
		})
	}
}
