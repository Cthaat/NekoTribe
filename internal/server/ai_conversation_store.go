package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"unicode/utf16"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

var (
	errConversationInvalid   = errors.New("conversation input invalid")
	errConversationNotFound  = errors.New("conversation not found")
	errConversationForbidden = errors.New("conversation access forbidden")
	errConversationSchema    = errors.New("conversation schema unavailable")
	conversationUUID         = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
)

type conversationRecord struct {
	ID        string  `json:"conversation_id"`
	Purpose   string  `json:"purpose"`
	GroupID   *int64  `json:"group_id"`
	Title     *string `json:"title"`
	CreatedAt string  `json:"created_at"`
	UpdatedAt string  `json:"updated_at"`
}
type conversationInput struct {
	Purpose string
	GroupID *int64
	Title   string
}
type moderationPolicy struct {
	AllowAll bool
	Accounts map[string]bool
}

func (s OracleSessions) createAIConversation(ctx context.Context, user int64, input conversationInput, policy moderationPolicy) (conversationRecord, error) {
	return s.conversationOperation(ctx, user, "", &input, policy, verifyConversationSchema)
}

func (s OracleSessions) readAIConversation(ctx context.Context, user int64, id string, policy moderationPolicy) (conversationRecord, error) {
	return s.conversationOperation(ctx, user, id, nil, policy, verifyConversationSchema)
}

func conversationPolicy(allowAll, accounts string) moderationPolicy {
	p := moderationPolicy{Accounts: make(map[string]bool)}
	switch strings.ToLower(strings.TrimSpace(allowAll)) {
	case "1", "true", "yes", "on":
		p.AllowAll = true
	}
	for _, value := range strings.Split(accounts, ",") {
		value = strings.ToLower(strings.TrimSpace(value))
		if value != "" {
			p.Accounts[value] = true
		}
	}
	if len(p.Accounts) == 0 {
		p.Accounts["v2_admin"] = true
	}
	return p
}

func validateConversationInput(input conversationInput) (conversationInput, error) {
	switch input.Purpose {
	case "knowledge", "writing", "moderation":
		if input.GroupID != nil {
			return input, errConversationInvalid
		}
	case "group":
		if input.GroupID == nil || *input.GroupID <= 0 || *input.GroupID > 9007199254740991 {
			return input, errConversationInvalid
		}
	default:
		return input, errConversationInvalid
	}
	input.Title = strings.TrimFunc(input.Title, jsTrimSpace)
	if len(utf16.Encode([]rune(input.Title))) > 200 {
		return input, errConversationInvalid
	}
	return input, nil
}

func verifyConversationSchema(ctx context.Context, conn *sql.Conn) error {
	var catalog schemaCatalog
	if json.Unmarshal(contracts.AIConversationSchemaCatalog, &catalog) != nil || validateFeatureSchema(ctx, conn, catalog, "ai-conversations") != nil {
		return errConversationSchema
	}
	return nil
}

func authorizeConversation(ctx context.Context, tx *sql.Tx, user int64, input conversationInput, policy moderationPolicy) error {
	switch input.Purpose {
	case "group":
		var allowed sql.NullInt64
		if tx.QueryRowContext(ctx, `SELECT fn_has_group_permission(:user_id,:group_id,:role) AS allowed FROM dual`, sql.Named("user_id", user), sql.Named("group_id", *input.GroupID), sql.Named("role", "admin")).Scan(&allowed) != nil {
			return errSessionStore
		}
		if !allowed.Valid || allowed.Int64 != 1 {
			return errConversationForbidden
		}
	case "moderation":
		if policy.AllowAll {
			return nil
		}
		var username, email sql.NullString
		err := tx.QueryRowContext(ctx, `SELECT username,email FROM n_users WHERE user_id=:user_id AND is_active=1 AND status='active'`, sql.Named("user_id", user)).Scan(&username, &email)
		if errors.Is(err, sql.ErrNoRows) {
			return errConversationForbidden
		}
		if err != nil {
			return errSessionStore
		}
		if !policy.Accounts[strings.ToLower(username.String)] && !policy.Accounts[strings.ToLower(email.String)] {
			return errConversationForbidden
		}
	}
	return nil
}

func readConversationRow(ctx context.Context, tx *sql.Tx, user int64, id string, policy moderationPolicy) (conversationRecord, error) {
	var result conversationRecord
	var group sql.NullInt64
	var title sql.NullString
	var created, updated sql.NullTime
	err := tx.QueryRowContext(ctx, `SELECT conversation_id,purpose,group_id,title,created_at,updated_at FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`, sql.Named("conversation_id", id), sql.Named("owner_user_id", user)).Scan(&result.ID, &result.Purpose, &group, &title, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return result, errConversationNotFound
	}
	if err != nil {
		return result, errSessionStore
	}
	if group.Valid {
		value := group.Int64
		result.GroupID = &value
	}
	result.Title = nullableString(title)
	if value := profileDate(created); value != nil {
		result.CreatedAt = *value
	}
	if value := profileDate(updated); value != nil {
		result.UpdatedAt = *value
	}
	input, err := validateConversationInput(conversationInput{Purpose: result.Purpose, GroupID: result.GroupID})
	if err != nil {
		return conversationRecord{}, errSessionStore
	}
	if err = authorizeConversation(ctx, tx, user, input, policy); err != nil {
		return conversationRecord{}, err
	}
	return result, nil
}

func (s OracleSessions) conversationOperation(ctx context.Context, user int64, id string, input *conversationInput, policy moderationPolicy, verify func(context.Context, *sql.Conn) error) (result conversationRecord, err error) {
	if user <= 0 || user > 9007199254740991 {
		return result, errConversationInvalid
	}
	if input == nil && !conversationUUID.MatchString(id) {
		return result, errConversationNotFound
	}
	if input != nil {
		value, e := validateConversationInput(*input)
		if e != nil {
			return result, e
		}
		input = &value
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return result, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			result = conversationRecord{}
			err = errSessionStore
		}
	}()
	if verify(ctx, conn) != nil {
		return result, errConversationSchema
	}
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return result, errSessionStore
	}
	commitStarted := false
	defer func() {
		if !commitStarted && tx.Rollback() != nil {
			result = conversationRecord{}
			err = errSessionStore
		}
	}()
	if input != nil {
		if e = authorizeConversation(ctx, tx, user, *input, policy); e != nil {
			return result, e
		}
		id, e = randomUUID()
		if e != nil {
			return result, errSessionStore
		}
		insert, e := tx.ExecContext(ctx, `INSERT INTO n_ai_conversations (conversation_id,owner_user_id,purpose,group_id,title) VALUES (:conversation_id,:owner_user_id,:purpose,:group_id,:title)`, sql.Named("conversation_id", id), sql.Named("owner_user_id", user), sql.Named("purpose", input.Purpose), sql.Named("group_id", input.GroupID), sql.Named("title", nullableRegistration(input.Title)))
		if e != nil {
			return result, errSessionStore
		}
		affected, e := insert.RowsAffected()
		if e != nil || affected != 1 {
			return result, errSessionStore
		}
	}
	result, e = readConversationRow(ctx, tx, user, id, policy)
	if e != nil {
		return conversationRecord{}, e
	}
	commitStarted = true
	if tx.Commit() != nil {
		return conversationRecord{}, errSessionStore
	}
	return result, nil
}
