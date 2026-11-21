package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type feedbackContract struct {
	Ratings []string
	Queries struct{ Schema, Lock, Message, Read, Save string }
}

var moderationFeedbackContract = func() feedbackContract {
	var contract feedbackContract
	if json.Unmarshal(contracts.AIModerationFeedback, &contract) != nil {
		panic("invalid moderation feedback contract")
	}
	return contract
}()

type moderationFeedbackReceipt struct {
	MessageID string `json:"message_id"`
	Rating    string `json:"rating"`
}

type moderationFeedbackStore interface {
	saveModerationFeedback(context.Context, int64, string, string, string, moderationPolicy) (moderationFeedbackReceipt, error)
}

func parseModerationRating(body []byte) (string, bool) {
	value, valid := ai.DecodeScalarJSON(body, 1)
	data, _ := value.(map[string]interface{})
	rating, _ := data["rating"].(string)
	return rating, valid && len(data) == 1 && !hasTooManyJSONMembers(body, 1) &&
		slices.Contains(moderationFeedbackContract.Ratings, rating)
}

func feedbackTablePresent(ctx context.Context, tx *sql.Tx) (bool, error) {
	var name string
	err := tx.QueryRowContext(ctx, moderationFeedbackContract.Queries.Schema).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil || name != "N_AI_MODERATION_FEEDBACK" {
		return false, errConversationSchema
	}
	return true, nil
}

func readModerationRating(ctx context.Context, tx *sql.Tx, messageID string) (string, error) {
	var rating string
	err := tx.QueryRowContext(ctx, moderationFeedbackContract.Queries.Read, sql.Named("message_id", messageID)).Scan(&rating)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil || !slices.Contains(moderationFeedbackContract.Ratings, rating) {
		return "", errConversationSchema
	}
	return rating, nil
}

func (s OracleSessions) saveModerationFeedback(ctx context.Context, actor int64, id, messageID, rating string, policy moderationPolicy) (receipt moderationFeedbackReceipt, err error) {
	if !conversationUUID.MatchString(id) || !conversationUUID.MatchString(messageID) {
		return receipt, errConversationNotFound
	}
	if !slices.Contains(moderationFeedbackContract.Ratings, rating) {
		return receipt, errConversationInvalid
	}
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return receipt, errConversationSchema
	}
	defer func() {
		if conn.Close() != nil || errors.Is(err, errSessionStore) {
			err = errConversationSchema
		}
	}()
	if verifyConversationSchema(ctx, conn) != nil {
		return receipt, errConversationSchema
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return receipt, errConversationSchema
	}
	defer func() {
		if rollback := tx.Rollback(); rollback != nil && !errors.Is(rollback, sql.ErrTxDone) {
			err = errConversationSchema
		}
	}()
	var locked string
	err = tx.QueryRowContext(ctx, moderationFeedbackContract.Queries.Lock,
		sql.Named("conversation_id", id), sql.Named("owner_user_id", actor)).Scan(&locked)
	if errors.Is(err, sql.ErrNoRows) {
		return receipt, errConversationNotFound
	}
	if err != nil || locked != id {
		return receipt, errConversationSchema
	}
	scope := conversationInput{Purpose: "moderation"}
	if err = authorizeConversation(ctx, tx, actor, scope, policy); err != nil {
		return receipt, err
	}
	var content string
	err = tx.QueryRowContext(ctx, moderationFeedbackContract.Queries.Message,
		sql.Named("conversation_id", id), sql.Named("message_id", messageID)).Scan(&content)
	if errors.Is(err, sql.ErrNoRows) {
		return receipt, errConversationNotFound
	}
	if err != nil {
		return receipt, errConversationSchema
	}
	advice := decodeModerationAdvice(content)
	if advice == nil {
		return receipt, errConversationConflict
	}
	if _, err = currentModerationAdvice(ctx, tx, actor, advice, true); err != nil {
		return receipt, err
	}
	if present, err := feedbackTablePresent(ctx, tx); err != nil || !present {
		return receipt, errConversationSchema
	}
	saved, err := tx.ExecContext(ctx, moderationFeedbackContract.Queries.Save,
		sql.Named("message_id", messageID), sql.Named("rating", rating))
	if err != nil {
		return receipt, errConversationSchema
	}
	if count, err := saved.RowsAffected(); err != nil || (count != 0 && count != 1) {
		return receipt, errConversationSchema
	}
	if err = authorizeConversation(ctx, tx, actor, scope, policy); err != nil {
		return receipt, err
	}
	if _, err = currentModerationAdvice(ctx, tx, actor, advice, false); err != nil {
		return receipt, err
	}
	if tx.Commit() != nil {
		return receipt, errConversationSchema
	}
	return moderationFeedbackReceipt{MessageID: messageID, Rating: rating}, nil
}
