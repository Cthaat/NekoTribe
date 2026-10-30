package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

var (
	errConversationInvalid   = errors.New("conversation input invalid")
	errConversationNotFound  = errors.New("conversation not found")
	errConversationForbidden = errors.New("conversation access forbidden")
	errConversationSchema    = errors.New("conversation schema unavailable")
	errConversationConflict  = errors.New("conversation changed")
	conversationUUID         = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	aiProfileID              = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
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
type assistantMessageInput struct {
	Content          string
	ExpectedSequence int64
	ModelID          string
	ConfigRevision   int64
}
type conversationMessage struct {
	ID             string `json:"message_id"`
	ConversationID string `json:"conversation_id"`
	SequenceNo     int64  `json:"sequence_no"`
	Role           string `json:"role"`
}
type conversationHistoryMessage struct {
	ID             string  `json:"message_id"`
	ConversationID string  `json:"conversation_id"`
	SequenceNo     int64   `json:"sequence_no"`
	Role           string  `json:"role"`
	Content        string  `json:"content"`
	ModelID        *string `json:"model_id"`
	ModelVersion   *string `json:"model_version"`
	ConfigRevision *int64  `json:"config_revision"`
	CreatedAt      string  `json:"created_at"`
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

func (s OracleSessions) appendAIUserMessage(ctx context.Context, user int64, id, content string, policy moderationPolicy) (conversationMessage, error) {
	return s.appendAIUserMessageOperation(ctx, user, id, content, policy, verifyConversationSchema)
}

// This method is for trusted server-side generation only, never direct client input.
func (s OracleSessions) appendAIAssistantMessage(ctx context.Context, user int64, id string, input assistantMessageInput, policy moderationPolicy) (conversationMessage, error) {
	return s.appendAIAssistantMessageOperation(ctx, user, id, input, policy, verifyConversationSchema)
}
func (s OracleSessions) listAIConversationMessages(ctx context.Context, user int64, id string, after, limit int64, policy moderationPolicy) ([]conversationHistoryMessage, error) {
	return s.listAIConversationMessagesOperation(ctx, user, id, after, limit, policy, verifyConversationSchema)
}
func (s OracleSessions) listAIRecentConversationMessages(ctx context.Context, user int64, id string, policy moderationPolicy) ([]conversationHistoryMessage, error) {
	return s.listAIHistoryOperation(ctx, user, id, 0, 50, policy, verifyConversationSchema, true)
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

func readConversationRow(ctx context.Context, tx *sql.Tx, user int64, id string, policy moderationPolicy, lock bool) (conversationRecord, error) {
	var result conversationRecord
	var group sql.NullInt64
	var title sql.NullString
	var created, updated sql.NullTime
	query := `SELECT conversation_id,purpose,group_id,title,created_at,updated_at FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`
	if lock {
		query += " FOR UPDATE"
	}
	err := tx.QueryRowContext(ctx, query, sql.Named("conversation_id", id), sql.Named("owner_user_id", user)).Scan(&result.ID, &result.Purpose, &group, &title, &created, &updated)
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
	result, e = readConversationRow(ctx, tx, user, id, policy, false)
	if e != nil {
		return conversationRecord{}, e
	}
	commitStarted = true
	if tx.Commit() != nil {
		return conversationRecord{}, errSessionStore
	}
	return result, nil
}

// The caller authenticates the actor and supplies a trusted moderation policy.
// The row lock serializes sequence allocation; no model call occurs in this transaction.
func (s OracleSessions) appendAIUserMessageOperation(ctx context.Context, user int64, id, content string, policy moderationPolicy, verify func(context.Context, *sql.Conn) error) (result conversationMessage, err error) {
	return s.appendAIMessageOperation(ctx, user, id, content, nil, policy, verify)
}
func (s OracleSessions) appendAIAssistantMessageOperation(ctx context.Context, user int64, id string, input assistantMessageInput, policy moderationPolicy, verify func(context.Context, *sql.Conn) error) (conversationMessage, error) {
	if input.ExpectedSequence < 1 || input.ExpectedSequence >= 9999999999 || !aiProfileID.MatchString(input.ModelID) || input.ConfigRevision < 1 || input.ConfigRevision > 999999999999999 {
		return conversationMessage{}, errConversationInvalid
	}
	return s.appendAIMessageOperation(ctx, user, id, input.Content, &input, policy, verify)
}
func (s OracleSessions) appendAIMessageOperation(ctx context.Context, user int64, id, content string, assistant *assistantMessageInput, policy moderationPolicy, verify func(context.Context, *sql.Conn) error) (result conversationMessage, err error) {
	if user <= 0 || user > 9007199254740991 {
		return result, errConversationInvalid
	}
	if !conversationUUID.MatchString(id) {
		return result, errConversationNotFound
	}
	if len(content) == 0 || len(content) > 65536 || !utf8.ValidString(content) {
		return result, errConversationInvalid
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return result, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			result = conversationMessage{}
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
			result = conversationMessage{}
			err = errSessionStore
		}
	}()
	record, e := readConversationRow(ctx, tx, user, id, policy, true)
	if e != nil {
		return result, e
	}
	var sequence int64
	if tx.QueryRowContext(ctx, `SELECT NVL(MAX(sequence_no),0)+1 AS next_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id`, sql.Named("conversation_id", id)).Scan(&sequence) != nil || sequence <= 0 || sequence > 9999999999 {
		return result, errSessionStore
	}
	role := "user"
	var modelID, revision interface{}
	if assistant != nil {
		if sequence != assistant.ExpectedSequence+1 {
			return result, errConversationConflict
		}
		role, modelID, revision = "assistant", assistant.ModelID, assistant.ConfigRevision
	}
	messageID, e := randomUUID()
	if e != nil {
		return result, errSessionStore
	}
	inserted, e := tx.ExecContext(ctx, `INSERT INTO n_ai_messages (message_id,conversation_id,sequence_no,role,content,model_id,config_revision) VALUES (:message_id,:conversation_id,:sequence_no,:role,:content,:model_id,:config_revision)`,
		sql.Named("message_id", messageID), sql.Named("conversation_id", id), sql.Named("sequence_no", sequence), sql.Named("role", role), sql.Named("content", content), sql.Named("model_id", modelID), sql.Named("config_revision", revision))
	if e != nil {
		return result, errSessionStore
	}
	if count, e := inserted.RowsAffected(); e != nil || count != 1 {
		return result, errSessionStore
	}
	updated, e := tx.ExecContext(ctx, `UPDATE n_ai_conversations SET updated_at=CURRENT_TIMESTAMP WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`, sql.Named("conversation_id", id), sql.Named("owner_user_id", user))
	if e != nil {
		return result, errSessionStore
	}
	if count, e := updated.RowsAffected(); e != nil || count != 1 {
		return result, errSessionStore
	}
	scope := conversationInput{Purpose: record.Purpose, GroupID: record.GroupID}
	if e = authorizeConversation(ctx, tx, user, scope, policy); e != nil {
		return result, e
	}
	commitStarted = true
	if tx.Commit() != nil {
		return result, errSessionStore
	}
	return conversationMessage{ID: messageID, ConversationID: id, SequenceNo: sequence, Role: role}, nil
}

// Never return fetched message content until ownership and current role have been rechecked.
func (s OracleSessions) listAIConversationMessagesOperation(ctx context.Context, user int64, id string, after, limit int64, policy moderationPolicy, verify func(context.Context, *sql.Conn) error) (result []conversationHistoryMessage, err error) {
	return s.listAIHistoryOperation(ctx, user, id, after, limit, policy, verify, false)
}
func (s OracleSessions) listAIHistoryOperation(ctx context.Context, user int64, id string, after, limit int64, policy moderationPolicy, verify func(context.Context, *sql.Conn) error, newest bool) (result []conversationHistoryMessage, err error) {
	if user <= 0 || user > 9007199254740991 || after < 0 || after > 9999999999 || limit < 1 || limit > 50 {
		return nil, errConversationInvalid
	}
	if !conversationUUID.MatchString(id) {
		return nil, errConversationNotFound
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return nil, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			result = nil
			err = errSessionStore
		}
	}()
	if verify(ctx, conn) != nil {
		return nil, errConversationSchema
	}
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return nil, errSessionStore
	}
	commitStarted := false
	defer func() {
		if !commitStarted && tx.Rollback() != nil {
			result = nil
			err = errSessionStore
		}
	}()
	if _, e = readConversationRow(ctx, tx, user, id, policy, false); e != nil {
		return nil, e
	}
	order := "ASC"
	if newest {
		order = "DESC"
	}
	rows, e := tx.QueryContext(ctx, `SELECT m.message_id,m.conversation_id,m.sequence_no,m.role,m.content,m.model_id,m.model_version,m.config_revision,m.created_at FROM n_ai_messages m JOIN n_ai_conversations c ON c.conversation_id=m.conversation_id WHERE m.conversation_id=:conversation_id AND c.owner_user_id=:owner_user_id AND m.sequence_no>:after_sequence ORDER BY m.sequence_no `+order+` FETCH FIRST :row_limit ROWS ONLY`,
		sql.Named("conversation_id", id), sql.Named("owner_user_id", user), sql.Named("after_sequence", after), sql.Named("row_limit", limit))
	if e != nil {
		return nil, errSessionStore
	}
	items := make([]conversationHistoryMessage, 0)
	for rows.Next() {
		var item conversationHistoryMessage
		var modelID, modelVersion sql.NullString
		var revision sql.NullInt64
		var created sql.NullTime
		if e = rows.Scan(&item.ID, &item.ConversationID, &item.SequenceNo, &item.Role, &item.Content, &modelID, &modelVersion, &revision, &created); e != nil {
			rows.Close()
			return nil, errSessionStore
		}
		item.ModelID = nullableString(modelID)
		item.ModelVersion = nullableString(modelVersion)
		if revision.Valid {
			value := revision.Int64
			item.ConfigRevision = &value
		}
		if value := profileDate(created); value != nil {
			item.CreatedAt = *value
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		rows.Close()
		return nil, errSessionStore
	}
	if rows.Close() != nil {
		return nil, errSessionStore
	}
	if newest {
		for left, right := 0, len(items)-1; left < right; left, right = left+1, right-1 {
			items[left], items[right] = items[right], items[left]
		}
	}
	if _, e = readConversationRow(ctx, tx, user, id, policy, false); e != nil {
		return nil, e
	}
	commitStarted = true
	if tx.Commit() != nil {
		return nil, errSessionStore
	}
	return items, nil
}
