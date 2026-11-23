package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

type directExtrasFixture struct {
	directSendConnector
	condition          string
	locks, attachments []int64
	storedText         string
	markCalls          int
	reacted            bool
}

type directExtrasFixtureConn struct {
	*directSendConn
	f *directExtrasFixture
}

func (f *directExtrasFixture) Connect(context.Context) (driver.Conn, error) {
	return &directExtrasFixtureConn{&directSendConn{&testConn{&f.state}, &f.directSendConnector}, f}, nil
}

func directFixtureBind(args []driver.NamedValue, key string) driver.Value {
	for _, arg := range args {
		if arg.Name == key {
			return arg.Value
		}
	}
	return nil
}

func (c *directExtrasFixtureConn) QueryContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	f := c.f
	statements := directExtrasContract.SQL
	rows := func(values ...driver.Value) (driver.Rows, error) { return &alertRows{values: values}, nil }
	empty := func() (driver.Rows, error) { return emptyRows{&f.state}, nil }
	stamp := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	switch q {
	case directSendAccessSQL, directHistoryAccessSQL:
		actor := directFixtureBind(args, "user_id")
		if directFixtureBind(args, "conversation_id") != int64(7) || (actor != int64(42) && actor != int64(9)) {
			return empty()
		}
		if q == directHistoryAccessSQL {
			return rows(int64(7))
		}
		if actor == int64(9) {
			return rows(int64(42))
		}
		return rows(int64(9))
	case statements["query_message"]:
		if directFixtureBind(args, "conversation_id") != int64(7) || f.condition == "cross-reply" || f.condition == "deleted" {
			return empty()
		}
		return rows(directFixtureBind(args, "message_id"))
	case statements["asset_lock"]:
		id, ok := directFixtureBind(args, "media_id").(int64)
		if !ok || directFixtureBind(args, "user_id") != int64(42) || f.condition == "foreign-asset" {
			return empty()
		}
		f.locks = append(f.locks, id)
		if f.condition == "bad-key" {
			return rows("posts/files/42/test.pdf")
		}
		return rows("private/chat/files/42/test.pdf")
	case statements["asset_free"]:
		if f.condition == "bound-asset" {
			return empty()
		}
		return rows(int64(1))
	case directMessageByIDSQL, directExactMessageSQL:
		if f.condition == "deleted" {
			return empty()
		}
		rel := "none"
		if q == directMessageByIDSQL || directFixtureBind(args, "viewer_id") == int64(42) {
			rel = "self"
		}
		return rows(int64(11), int64(7), int64(42), f.storedText, int64(0), stamp, stamp, nil, nil, "author", nil, nil, nil, nil, nil, int64(0), int64(0), int64(0), int64(0), int64(0), rel)
	case statements["list_media"]:
		items := make([][]driver.Value, 0, len(f.attachments))
		for _, id := range f.attachments {
			items = append(items, []driver.Value{int64(11), id, int64(42), "file", "test.pdf", "private/chat/files/42/test.pdf", int64(12), "application/pdf", nil, nil, nil, "private/chat/thumbnail", nil, nil, "ready", stamp, stamp})
		}
		return &schemaFixtureRows{columns: make([]string, 17), values: items}, nil
	case statements["list_replies"]:
		return rows(int64(11), int64(10), "quoted", "Alice")
	case statements["list_reactions"]:
		if !f.reacted {
			return empty()
		}
		viewer := int64(0)
		if directFixtureBind(args, "viewer_id") == int64(42) {
			viewer = 1
		}
		return rows(int64(11), "👍", int64(1), viewer)
	}
	return c.directSendConn.QueryContext(ctx, q, args)
}

func (c *directExtrasFixtureConn) ExecContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	f := c.f
	switch {
	case strings.HasPrefix(q, "INSERT INTO n_direct_messages"):
		f.storedText = directFixtureBind(args, "content").(string)
	case q == directExtrasContract.SQL["insert_media"]:
		id := directFixtureBind(args, "media_id").(int64)
		if directFixtureBind(args, "position") != int64(len(f.attachments)+1) {
			return nil, errors.New("incorrect media position")
		}
		f.attachments = append(f.attachments, id)
	case q == markDirectReadSQL:
		f.markCalls++
	case q == directExtrasContract.SQL["add_reaction"] || q == directExtrasContract.SQL["remove_reaction"]:
		if directFixtureBind(args, "user_id") != int64(42) || directFixtureBind(args, "emoji") != "👍" {
			return nil, errors.New("unscoped reaction")
		}
		newState := q == directExtrasContract.SQL["add_reaction"]
		if f.reacted == newState {
			return driver.RowsAffected(0), nil
		}
		f.reacted = newState
		return driver.RowsAffected(1), nil
	}
	return c.directSendConn.ExecContext(ctx, q, args)
}

func TestDirectExtrasSendTransactionLocksAndKeepsAttachmentOrder(t *testing.T) {
	for _, condition := range []string{"", "cross-reply", "foreign-asset", "bad-key", "bound-asset"} {
		t.Run(condition, func(t *testing.T) {
			f := &directExtrasFixture{condition: condition}
			db := sql.OpenDB(f)
			defer db.Close()
			reply := int64(10)
			result, err := sendDirectMessageOn(context.Background(), db, 42, 7, chatSendInput{media: []int64{88, 77}, reply: &reply}, StorageURLPolicy{})
			if condition != "" {
				want := errDirectAttachment
				if condition == "cross-reply" {
					want = errDirectReply
				}
				if !errors.Is(err, want) || result.message.ID != 0 || f.writes != 0 || f.state.commits != 0 {
					t.Fatal(err, f.writes, f.state.commits)
				}
				return
			}
			if err != nil || f.state.commits != 1 || f.storedText != " " || result.message.Content != "" || result.message.Reply == nil || result.message.Reply.ID != 10 || !slices.Equal(f.locks, []int64{77, 88}) || !slices.Equal(f.attachments, []int64{88, 77}) {
				t.Fatal(err, result.message, f.locks, f.attachments)
			}
			if media := result.message.Media; len(media) != 2 || media[0].PublicURL != "/api/v2/media/88/content" || media[1].PublicURL != "/api/v2/media/77/content" || media[0].ThumbnailURL != nil {
				t.Fatal("private URLs were not normalized", media)
			}
		})
	}
}

func TestDirectExtrasExactAndReactionsNeverMarkRead(t *testing.T) {
	f := &directExtrasFixture{storedText: "hello"}
	db := sql.OpenDB(f)
	defer db.Close()
	ctx := context.Background()
	for i, add := range []bool{true, true, false, false} {
		result, err := setDirectReactionOn(ctx, db, 42, 7, 11, "👍", add, StorageURLPolicy{})
		if err != nil || result.changed != (i%2 == 0) || result.target != 9 || (len(result.message.Reactions) > 0) != add {
			t.Fatal(err, result)
		}
		if add && !result.message.Reactions[0].Reacted {
			t.Fatal(result.message)
		}
		if add {
			other, err := getDirectMessageOn(ctx, db, 9, 7, 11, StorageURLPolicy{})
			if err != nil || len(other.Reactions) != 1 || other.Reactions[0].Reacted || other.CanDelete {
				t.Fatal(err, other)
			}
		}
	}
	if _, err := getDirectMessageOn(ctx, db, 12, 7, 11, StorageURLPolicy{}); !errors.Is(err, errDirectConversationForbidden) {
		t.Fatal(err)
	}
	f.condition = "deleted"
	if _, err := setDirectReactionOn(ctx, db, 42, 7, 11, "👍", true, StorageURLPolicy{}); !errors.Is(err, errDirectMessageMissing) {
		t.Fatal(err)
	}
	if f.markCalls != 0 {
		t.Fatal("exact receipt or reactions moved the read cursor")
	}
}

type directExtrasHTTPFixture struct {
	*memorySessions
	db *sql.DB
}

func (f *directExtrasHTTPFixture) GetDirectMessage(ctx context.Context, actor, conversation, message int64, storage StorageURLPolicy) (DirectMessage, error) {
	return getDirectMessageOn(ctx, f.db, actor, conversation, message, storage)
}

func (f *directExtrasHTTPFixture) SetDirectReaction(ctx context.Context, actor, conversation, message int64, emoji string, add bool, storage StorageURLPolicy) (directReactionResult, error) {
	return setDirectReactionOn(ctx, f.db, actor, conversation, message, emoji, add, storage)
}

type directUpdatedFixture struct {
	directPublisherFunc
	publish func(actor, target, conversation, message int64)
}

func (f directUpdatedFixture) PublishDirectUpdated(_ context.Context, actor, target, conversation, message int64) error {
	f.publish(actor, target, conversation, message)
	return nil
}

func TestDirectExtrasReactionRoutePublishesOnlyCommittedChanges(t *testing.T) {
	fixtureDB := &directExtrasFixture{storedText: "hello"}
	db := sql.OpenDB(fixtureDB)
	defer db.Close()
	codec, tokens := fixture(t)
	repo := &directExtrasHTTPFixture{memorySessions: store(), db: db}
	updates := 0
	publisher := directUpdatedFixture{publish: func(actor, target, conversation, message int64) {
		if actor != 42 || target != 9 || conversation != 7 || message != 11 || fixtureDB.state.commits == 0 {
			t.Fatal("invalid committed update scope")
		}
		updates++
	}}
	handler := NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{DirectEvents: publisher})
	const path = "/api/v2/chat/direct-conversations/7/messages/11"
	for _, tc := range []struct {
		method, endpoint, body string
		status, updates        int
	}{
		{http.MethodPost, path + "/reactions", `{"emoji":" 👍 "}`, 200, 1},
		{http.MethodPost, path + "/reactions", `{"emoji":"👍"}`, 200, 1},
		{http.MethodGet, path, "", 200, 1},
		{http.MethodDelete, path + "/reactions", `{"emoji":"👍"}`, 200, 2},
		{http.MethodDelete, path + "/reactions", `{"emoji":"👍"}`, 200, 2},
		{http.MethodPost, path + "/reactions", `{"emoji":""}`, 400, 2},
	} {
		r := httptest.NewRequest(tc.method, tc.endpoint, strings.NewReader(tc.body))
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, r)
		if response.Code != tc.status || response.Header().Get("Cache-Control") != "private, no-store" || updates != tc.updates || fixtureDB.markCalls != 0 {
			t.Fatal(response.Code, updates, response.Body.String())
		}
	}
}
