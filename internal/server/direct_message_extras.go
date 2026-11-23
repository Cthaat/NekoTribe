package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type directMessageExtrasDefinition struct {
	MaxMedia           int               `json:"max_media"`
	MaxContentBytes    int               `json:"max_content_bytes"`
	MaxEmojiBytes      int               `json:"max_emoji_bytes"`
	MaxEmojiUTF16Units int               `json:"max_emoji_utf16_units"`
	SQL                map[string]string `json:"sql"`
}

var directExtrasContract = func() directMessageExtrasDefinition {
	var definition directMessageExtrasDefinition
	if json.Unmarshal(contracts.DirectMessageExtras, &definition) != nil || definition.MaxMedia < 1 || definition.MaxContentBytes < 1 || definition.MaxEmojiBytes < 1 || definition.MaxEmojiUTF16Units < 1 {
		panic("invalid direct message extras contract")
	}
	return definition
}()

var (
	errDirectExtrasUnavailable = errors.New("direct message extras unavailable")
	errDirectReply             = errors.New("invalid direct message reply")
	errDirectAttachment        = errors.New("direct message attachment unavailable")
)

func parseDirectSend(raw []byte) (chatSendInput, error) {
	var input chatSendInput
	decoded, valid := ai.DecodeScalarJSON(raw, 6)
	body, object := decoded.(map[string]any)
	if !valid || !object || hasTooManyJSONMembers(raw, len(body)) {
		return input, errConversationInvalid
	}
	for key, value := range body {
		switch key {
		case "content":
			text, ok := value.(string)
			if !ok {
				return input, errConversationInvalid
			}
			input.content = strings.TrimFunc(text, jsTrimSpace)
			if len(input.content) > directExtrasContract.MaxContentBytes {
				return input, errConversationInvalid
			}
		case "reply_to_message_id":
			if value == nil {
				continue
			}
			id, ok := chatSendID(value)
			if !ok {
				return input, errConversationInvalid
			}
			input.reply = &id
		case "media_ids":
			items, ok := value.([]any)
			if !ok || len(items) > directExtrasContract.MaxMedia {
				return input, errConversationInvalid
			}
			seen := make(map[int64]bool, len(items))
			for _, rawID := range items {
				id, ok := chatSendID(rawID)
				if !ok || seen[id] {
					return input, errConversationInvalid
				}
				seen[id] = true
				input.media = append(input.media, id)
			}
		default:
			return input, errConversationInvalid
		}
	}
	if input.content == "" && len(input.media) == 0 {
		return input, errConversationInvalid
	}
	return input, nil
}

func parseDirectReaction(raw []byte) (string, error) {
	decoded, valid := ai.DecodeScalarJSON(raw, 4)
	body, object := decoded.(map[string]any)
	emoji, stringValue := body["emoji"].(string)
	if !valid || !object || len(body) != 1 || !stringValue || hasTooManyJSONMembers(raw, 1) {
		return "", errConversationInvalid
	}
	emoji = strings.TrimFunc(emoji, jsTrimSpace)
	if !validDirectEmoji(emoji) {
		return "", errConversationInvalid
	}
	return emoji, nil
}

func validDirectEmoji(value string) bool {
	return value != "" && utf8.ValidString(value) && len(value) <= directExtrasContract.MaxEmojiBytes && len(utf16.Encode([]rune(value))) <= directExtrasContract.MaxEmojiUTF16Units
}

func directVisibleContent(content string) string {
	if content == " " {
		return ""
	}
	return content
}

func (s OracleSessions) directExtrasConnection(ctx context.Context) (*sql.Conn, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errSessionStore
	}
	var catalog schemaCatalog
	if json.Unmarshal(contracts.DirectMessageExtrasSchemaCatalog, &catalog) != nil || validateFeatureSchema(ctx, conn, catalog, "direct-message-extras") != nil {
		_ = conn.Close()
		return nil, errDirectExtrasUnavailable
	}
	return conn, nil
}

func directExtrasAbsent(ctx context.Context, db interface {
	publicProfileQueryer
	schemaQueryer
}, probe string, err error) bool {
	if !oracleErrorCode(err, "ORA-00942") || !schemaOwnerMatches(ctx, db) {
		return false
	}
	var present int
	return errors.Is(db.QueryRowContext(ctx, directExtrasContract.SQL[probe]).Scan(&present), sql.ErrNoRows)
}

func directExtrasReadError(err error) error {
	if err != nil && privateMediaSchemaMissing(err) {
		return errDirectExtrasUnavailable
	}
	return errSessionStore
}

func validateDirectReply(ctx context.Context, tx *sql.Tx, conversation int64, reply *int64) error {
	if reply == nil {
		return nil
	}
	var found int64
	err := tx.QueryRowContext(ctx, directExtrasContract.SQL["query_message"], sql.Named("conversation_id", conversation), sql.Named("message_id", *reply)).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errDirectReply
	}
	if err != nil || found != *reply {
		return errSessionStore
	}
	return nil
}

func lockDirectAttachments(ctx context.Context, tx *sql.Tx, actor int64, ids []int64) error {
	ordered := slices.Clone(ids)
	slices.Sort(ordered)
	for _, id := range ordered {
		media := sql.Named("media_id", id)
		var key sql.NullString
		err := tx.QueryRowContext(ctx, directExtrasContract.SQL["asset_lock"], media, sql.Named("user_id", actor)).Scan(&key)
		if errors.Is(err, sql.ErrNoRows) {
			return errDirectAttachment
		}
		if err != nil {
			return errSessionStore
		}
		if _, err := normalizePrivateMediaStorageKey(key.String, "chat"); err != nil {
			return errDirectAttachment
		}
		var allowed int
		err = tx.QueryRowContext(ctx, directExtrasContract.SQL["asset_free"], media).Scan(&allowed)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && allowed != 1) {
			return errDirectAttachment
		}
		if err != nil {
			return errSessionStore
		}
	}
	return nil
}

func directAssetLinked(ctx context.Context, db *sql.Tx, media sql.NamedArg) (bool, error) {
	var found int
	err := db.QueryRowContext(ctx, directExtrasContract.SQL["asset_is_linked"], media).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) || directExtrasAbsent(ctx, db, "attachment_table_present", err) {
		return false, nil
	}
	if err != nil || found != 1 {
		return false, errSessionStore
	}
	return true, nil
}
