package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"
)

type conversationDB struct {
	driverState
	mode            string
	permissionCalls int
	owner           int64
	id              string
	purpose         string
	group           driver.Value
	title           driver.Value
	calls           []listQueryCall
	messages        int64
	messageContent  string
	messageRole     string
	messageModel    driver.Value
	messageRevision driver.Value
}
type conversationConnector struct{ state *conversationDB }
type conversationConn struct {
	*testConn
	state *conversationDB
}
type conversationTx struct{ state *conversationDB }

func TestDeleteConversationLocksAndRechecksPermission(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	for _, mode := range []string{"ok", "revoked", "commit"} {
		t.Run(mode, func(t *testing.T) {
			state := &conversationDB{mode: mode, owner: 42, id: id, purpose: "group", group: int64(7)}
			db := sql.OpenDB(conversationConnector{state})
			defer db.Close()
			err := (OracleSessions{db}).deleteAIConversationOperation(context.Background(), 42, id, conversationPolicy("", ""), func(context.Context, *sql.Conn) error { return nil })
			if mode == "ok" && (err != nil || state.commits != 1 || state.permissionCalls != 2) {
				t.Fatal(err, state)
			}
			if mode == "revoked" && (!errors.Is(err, errConversationForbidden) || state.rollbacks != 1) {
				t.Fatal(err, state)
			}
			if mode == "commit" && (err == nil || state.rollbacks != 0) {
				t.Fatal(err, state)
			}
			if len(state.calls) < 2 || !strings.Contains(state.calls[0].sql, "FOR UPDATE") {
				t.Fatal(state.calls)
			}
			found := false
			for _, call := range state.calls {
				if strings.Contains(call.sql, "DELETE FROM n_ai_conversations") {
					found = strings.Contains(call.sql, "owner_user_id=:owner_user_id") && len(call.args) == 2
				}
			}
			if !found {
				t.Fatal("delete must be scoped to owner and conversation", state.calls)
			}
		})
	}
}

func (c conversationConnector) Connect(context.Context) (driver.Conn, error) {
	return &conversationConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (conversationConnector) Driver() driver.Driver   { return testDriver{} }
func (c *conversationConn) Begin() (driver.Tx, error) { return &conversationTx{c.state}, nil }
func (tx *conversationTx) Commit() error {
	tx.state.commits++
	if tx.state.mode == "commit" {
		return errors.New("private")
	}
	return nil
}
func (tx *conversationTx) Rollback() error {
	tx.state.rollbacks++
	if tx.state.mode == "rollback" {
		return errors.New("private")
	}
	return nil
}
func (c *conversationConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.state.calls = append(c.state.calls, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if c.state.mode == "insert" {
		return nil, errors.New("private")
	}
	if strings.Contains(query, "INSERT INTO n_ai_messages") {
		for _, arg := range args {
			if arg.Name == "content" {
				c.state.messageContent = arg.Value.(string)
			}
			if arg.Name == "role" {
				c.state.messageRole = arg.Value.(string)
			}
			if arg.Name == "model_id" {
				c.state.messageModel = arg.Value
			}
			if arg.Name == "config_revision" {
				c.state.messageRevision = arg.Value
			}
		}
		c.state.messages++
		return driver.RowsAffected(1), nil
	}
	if strings.Contains(query, "UPDATE n_ai_conversations") {
		return driver.RowsAffected(1), nil
	}
	for _, arg := range args {
		switch arg.Name {
		case "conversation_id":
			c.state.id = arg.Value.(string)
		case "owner_user_id":
			c.state.owner = arg.Value.(int64)
		case "purpose":
			c.state.purpose = arg.Value.(string)
		case "group_id":
			c.state.group = arg.Value
		case "title":
			c.state.title = arg.Value
		}
	}
	return driver.RowsAffected(1), nil
}

func TestAppendAssistantMessageChecksVersionAndCurrentSequence(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	for _, mode := range []string{"ok", "stale", "revoked", "invalid", "commit"} {
		t.Run(mode, func(t *testing.T) {
			state := &conversationDB{mode: mode, owner: 42, id: id, purpose: "group", group: int64(7), messages: 1}
			db := sql.OpenDB(conversationConnector{state})
			defer db.Close()
			input := assistantMessageInput{Content: "result", ExpectedSequence: 1, ModelID: "profile-a", ConfigRevision: 12}
			if mode == "stale" {
				input.ExpectedSequence = 2
			}
			if mode == "invalid" {
				input.ConfigRevision = 1000000000000000
			}
			result, err := (OracleSessions{db}).appendAIAssistantMessageOperation(context.Background(), 42, id, input, conversationPolicy("", ""), func(context.Context, *sql.Conn) error { return nil })
			if mode == "ok" {
				if err != nil || result.SequenceNo != 2 || result.Role != "assistant" || state.messageModel != "profile-a" || state.messageRevision != int64(12) || state.messageRole != "assistant" || state.permissionCalls != 2 || state.commits != 1 {
					t.Fatal(result, err, state)
				}
			} else {
				if err == nil || strings.Contains(err.Error(), "private") {
					t.Fatal(err)
				}
				if mode == "stale" && (!errors.Is(err, errConversationConflict) || state.messages != 1 || state.rollbacks != 1) {
					t.Fatal(err, state)
				}
				if mode == "invalid" && (!errors.Is(err, errConversationInvalid) || len(state.calls) != 0) {
					t.Fatal(err, state)
				}
				if mode == "revoked" && (!errors.Is(err, errConversationForbidden) || state.rollbacks != 1) {
					t.Fatal(err, state)
				}
				if mode == "commit" && (state.commits != 1 || state.rollbacks != 0) {
					t.Fatal(err, state)
				}
			}
		})
	}
}
func (c *conversationConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.calls = append(c.state.calls, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if strings.Contains(query, "FROM n_ai_conversations c WHERE") {
		if !strings.Contains(query, "c.owner_user_id=:owner_user_id") || !strings.Contains(query, "fn_has_group_permission") || !strings.Contains(query, "ORDER BY c.conversation_id ASC") {
			return nil, errors.New("unsafe list query")
		}
		binds := map[string]driver.Value{}
		for _, arg := range args {
			binds[arg.Name] = arg.Value
		}
		if binds["owner_user_id"] != int64(42) || binds["moderation_allowed"] != int64(0) || binds["row_limit"] != int64(3) {
			return nil, errors.New("wrong bindings")
		}
		stamp := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
		return &alertRows{values: []driver.Value{c.state.id, int64(42), "writing", nil, "draft", stamp, stamp}}, nil
	}
	if strings.Contains(query, "fn_has_group_permission") {
		c.state.permissionCalls++
		if c.state.mode == "denied" || (c.state.mode == "revoked" && c.state.permissionCalls > 1) || c.state.mode == "rollback" {
			return &alertRows{values: []driver.Value{int64(0)}}, nil
		}
		return &alertRows{values: []driver.Value{int64(1)}}, nil
	}
	if strings.Contains(query, "SELECT username,email") {
		return &alertRows{values: []driver.Value{"v2_admin", "admin@example.test"}}, nil
	}
	if strings.Contains(query, "MAX(sequence_no)") {
		return &alertRows{values: []driver.Value{c.state.messages + 1}}, nil
	}
	if strings.Contains(query, "FROM n_ai_messages m") {
		if c.state.mode == "message-error" {
			return nil, errors.New("private")
		}
		newest := strings.Contains(query, "ORDER BY m.sequence_no DESC")
		if !strings.Contains(query, "c.owner_user_id=:owner_user_id") || (!newest && !strings.Contains(query, "ORDER BY m.sequence_no ASC")) {
			return nil, errors.New("unsafe query")
		}
		got := make(map[string]driver.Value)
		for _, arg := range args {
			got[arg.Name] = arg.Value
		}
		after, limit := int64(1), int64(10)
		if newest {
			after, limit = 0, 50
		}
		if got["owner_user_id"] != int64(42) || got["after_sequence"] != after || got["row_limit"] != limit || got["conversation_id"] != c.state.id {
			return nil, errors.New("incorrect page bindings")
		}
		if c.state.mode == "empty" {
			return emptyRows{&c.state.driverState}, nil
		}
		stamp := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
		return &alertRows{values: []driver.Value{"a0f0f322-b5a7-4a4a-b843-3d0ea0d244dd", c.state.id, int64(2), "user", "第二条", nil, nil, nil, stamp}}, nil
	}
	if strings.Contains(query, "FROM n_ai_conversations") {
		if c.state.mode == "read" {
			return nil, errors.New("private")
		}
		var id string
		var owner int64
		for _, arg := range args {
			if arg.Name == "conversation_id" {
				id = arg.Value.(string)
			}
			if arg.Name == "owner_user_id" {
				owner = arg.Value.(int64)
			}
		}
		if owner != c.state.owner || id != c.state.id {
			return emptyRows{&c.state.driverState}, nil
		}
		stamp := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
		return &alertRows{values: []driver.Value{id, c.state.purpose, c.state.group, c.state.title, stamp, stamp}}, nil
	}
	return nil, errors.New("unexpected")
}

func TestRecentConversationHistoryUsesOwnerAndDescendingWindow(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	state := &conversationDB{owner: 42, id: id, purpose: "group", group: int64(7)}
	db := sql.OpenDB(conversationConnector{state})
	defer db.Close()
	items, err := (OracleSessions{db}).listAIHistoryOperation(context.Background(), 42, id, 0, 50, conversationPolicy("", ""), func(context.Context, *sql.Conn) error { return nil }, true)
	if err != nil || len(items) != 1 || items[0].Content != "第二条" || state.permissionCalls != 2 {
		t.Fatal(items, err, state)
	}
}

func TestConversationMessageHistory(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	for _, mode := range []string{"ok", "empty", "foreign", "revoked", "message-error", "invalid"} {
		t.Run(mode, func(t *testing.T) {
			state := &conversationDB{mode: mode, owner: 42, id: id, purpose: "group", group: int64(7)}
			db := sql.OpenDB(conversationConnector{state})
			defer db.Close()
			user, limit := int64(42), int64(10)
			if mode == "foreign" {
				user = 9
			}
			if mode == "invalid" {
				limit = 51
			}
			result, err := (OracleSessions{db}).listAIConversationMessagesOperation(context.Background(), user, id, 1, limit, conversationPolicy("", ""), func(context.Context, *sql.Conn) error { return nil })
			if mode == "empty" {
				if err != nil || result == nil || len(result) != 0 || state.permissionCalls != 2 {
					t.Fatal(result, err, state)
				}
			} else if mode == "ok" {
				if err != nil || len(result) != 1 || result[0].SequenceNo != 2 || result[0].Content != "第二条" || state.permissionCalls != 2 || state.commits != 1 {
					t.Fatal(result, err, state)
				}
			} else {
				if err == nil || len(result) != 0 || strings.Contains(err.Error(), "private") {
					t.Fatal(result, err)
				}
				if mode == "foreign" && !errors.Is(err, errConversationNotFound) {
					t.Fatal(err)
				}
				if mode == "revoked" && !errors.Is(err, errConversationForbidden) {
					t.Fatal(err)
				}
				if mode == "invalid" && (!errors.Is(err, errConversationInvalid) || len(state.calls) != 0) {
					t.Fatal(err, state)
				}
			}
		})
	}
}

func TestAppendConversationUserMessage(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	for _, mode := range []string{"ok", "revoked", "commit", "foreign", "oversize", "insert", "sequence-limit"} {
		t.Run(mode, func(t *testing.T) {
			state := &conversationDB{mode: mode, owner: 42, id: id, purpose: "group", group: int64(7)}
			if mode == "sequence-limit" {
				state.messages = 9999999999
			}
			db := sql.OpenDB(conversationConnector{state})
			defer db.Close()
			user, content := int64(42), "hello"
			if mode == "foreign" {
				user = 9
			}
			if mode == "oversize" {
				content = strings.Repeat("猫", 21846)
			}
			result, err := (OracleSessions{db}).appendAIUserMessageOperation(context.Background(), user, id, content, conversationPolicy("", ""), func(context.Context, *sql.Conn) error { return nil })
			if mode == "ok" {
				if err != nil || result.SequenceNo != 1 || result.Role != "user" || state.messageContent != content || state.commits != 1 || state.permissionCalls != 2 {
					t.Fatal(result, err, state)
				}
				locked := false
				for _, call := range state.calls {
					if strings.Contains(call.sql, "FOR UPDATE") && strings.Contains(call.sql, "owner_user_id=:owner_user_id") {
						locked = true
					}
				}
				if !locked {
					t.Fatal("missing owned conversation lock")
				}
				next, nextErr := (OracleSessions{db}).appendAIUserMessageOperation(context.Background(), user, id, "next", conversationPolicy("", ""), func(context.Context, *sql.Conn) error { return nil })
				if nextErr != nil || next.SequenceNo != 2 {
					t.Fatal(next, nextErr)
				}
			} else {
				if err == nil || strings.Contains(err.Error(), "private") {
					t.Fatal(err)
				}
				if mode == "revoked" && (!errors.Is(err, errConversationForbidden) || state.rollbacks != 1 || state.commits != 0) {
					t.Fatal(err, state)
				}
				if mode == "foreign" && !errors.Is(err, errConversationNotFound) {
					t.Fatal(err)
				}
				if mode == "oversize" && (!errors.Is(err, errConversationInvalid) || len(state.calls) != 0) {
					t.Fatal(err, state)
				}
				if mode == "commit" && (state.commits != 1 || state.rollbacks != 0) {
					t.Fatal(err, state)
				}
				if (mode == "insert" || mode == "sequence-limit") && (state.commits != 0 || state.rollbacks != 1) {
					t.Fatal(err, state)
				}
			}
		})
	}
}

func TestConversationCreateTransactionAndAuthorization(t *testing.T) {
	group := int64(7)
	for _, mode := range []string{"ok", "schema", "denied", "revoked", "insert", "read", "commit", "rollback"} {
		t.Run(mode, func(t *testing.T) {
			state := &conversationDB{mode: mode}
			db := sql.OpenDB(conversationConnector{state})
			defer db.Close()
			verify := func(context.Context, *sql.Conn) error {
				if mode == "schema" {
					return errConversationSchema
				}
				return nil
			}
			result, err := (OracleSessions{db}).conversationOperation(context.Background(), 42, "", &conversationInput{Purpose: "group", GroupID: &group, Title: " hello "}, conversationPolicy("", ""), verify)
			if mode == "ok" {
				if err != nil || result.Purpose != "group" || result.GroupID == nil || *result.GroupID != 7 || result.Title == nil || *result.Title != "hello" || state.permissionCalls != 2 || state.commits != 1 || state.rollbacks != 0 {
					t.Fatal(result, err, state)
				}
			} else {
				if err == nil || strings.Contains(err.Error(), "private") || state.commits != boolNumber(mode == "commit") || state.rollbacks != boolNumber(mode != "schema" && mode != "commit") {
					t.Fatal(result, err, state)
				}
				if mode == "revoked" && !errors.Is(err, errConversationForbidden) {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestConversationReadOwnerAndPolicy(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	state := &conversationDB{owner: 42, id: id, purpose: "moderation"}
	db := sql.OpenDB(conversationConnector{state})
	defer db.Close()
	verify := func(context.Context, *sql.Conn) error { return nil }
	repo := OracleSessions{db}
	if _, err := repo.conversationOperation(context.Background(), 9, id, nil, conversationPolicy("", ""), verify); !errors.Is(err, errConversationNotFound) {
		t.Fatal(err)
	}
	if _, err := repo.conversationOperation(context.Background(), 42, id, nil, conversationPolicy("", "someone-else"), verify); !errors.Is(err, errConversationForbidden) {
		t.Fatal(err)
	}
	if _, err := repo.conversationOperation(context.Background(), 42, id, nil, conversationPolicy("", "v2_admin"), verify); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.conversationOperation(context.Background(), 42, "invalid", nil, conversationPolicy("", ""), verify); !errors.Is(err, errConversationNotFound) {
		t.Fatal(err)
	}
}
