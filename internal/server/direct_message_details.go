package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

func loadDirectMessageExtras(ctx context.Context, tx *sql.Tx, viewer int64, items []DirectMessage, allowLegacy bool) error {
	if len(items) == 0 {
		return nil
	}
	ids := make([]int64, 0, len(items))
	messages := make(map[int64]*DirectMessage, len(items))
	for i := range items {
		ids = append(ids, items[i].ID)
		messages[items[i].ID] = &items[i]
	}
	encoded, err := json.Marshal(ids)
	if err != nil {
		return errSessionStore
	}
	boundIDs := sql.Named("message_ids", string(encoded))
	_, err = collectChatRows(ctx, tx, directExtrasContract.SQL["list_media"], []any{boundIDs}, func(row *sql.Rows) (struct{}, error) {
		id, owner, media, err := scanDirectMessageMedia(row)
		if err != nil {
			return struct{}{}, err
		}
		message := messages[id]
		if message == nil || owner != message.Author.UserID || len(message.Media) >= directExtrasContract.MaxMedia {
			return struct{}{}, errSessionStore
		}
		message.Media = append(message.Media, media)
		return struct{}{}, nil
	})
	if err != nil {
		if allowLegacy && directExtrasAbsent(ctx, tx, "any_extras_table_present", err) {
			return nil
		}
		return directExtrasReadError(err)
	}
	_, err = collectChatRows(ctx, tx, directExtrasContract.SQL["list_replies"], []any{boundIDs}, func(row *sql.Rows) (struct{}, error) {
		var id int64
		var reply chatReply
		var text, author sql.NullString
		if err := row.Scan(&id, &reply.ID, &text, &author); err != nil || reply.ID <= 0 || reply.ID > maxSocketID {
			return struct{}{}, errSessionStore
		}
		message := messages[id]
		if message == nil || message.Reply != nil {
			return struct{}{}, errSessionStore
		}
		reply.Content, reply.AuthorName = directVisibleContent(text.String), author.String
		message.Reply = &reply
		return struct{}{}, nil
	})
	if err != nil {
		return directExtrasReadError(err)
	}
	_, err = collectChatRows(ctx, tx, directExtrasContract.SQL["list_reactions"], []any{boundIDs, sql.Named("viewer_id", viewer)}, func(row *sql.Rows) (struct{}, error) {
		var id, reacted int64
		var reaction chatReaction
		if err := row.Scan(&id, &reaction.Emoji, &reaction.Count, &reacted); err != nil || !validDirectEmoji(reaction.Emoji) || reaction.Count < 1 || (reacted != 0 && reacted != 1) {
			return struct{}{}, errSessionStore
		}
		message := messages[id]
		if message == nil {
			return struct{}{}, errSessionStore
		}
		reaction.Reacted = reacted == 1
		message.Reactions = append(message.Reactions, reaction)
		return struct{}{}, nil
	})
	if err != nil {
		return directExtrasReadError(err)
	}
	return nil
}

func scanDirectMessageMedia(row notificationScanner) (int64, int64, PostMedia, error) {
	var id, owner int64
	var media PostMedia
	var kind, name, storedURL, mime, storedThumbnail, alt, desc, status sql.NullString
	var size sql.NullInt64
	var width, height, duration sql.NullFloat64
	var created, updated sql.NullTime
	if err := row.Scan(&id, &media.MediaID, &owner, &kind, &name, &storedURL, &size, &mime, &width, &height, &duration,
		&storedThumbnail, &alt, &desc, &status, &created, &updated); err != nil || media.MediaID <= 0 || media.MediaID > maxSocketID || status.String != "ready" {
		return 0, 0, PostMedia{}, errSessionStore
	}
	media.MediaType, media.FileName, media.PublicURL = kind.String, name.String, privateMediaContentPath(media.MediaID)
	media.FileSize, media.MIMEType = size.Int64, mime.String
	media.Width, media.Height, media.Duration = nullableFloat(width), nullableFloat(height), nullableFloat(duration)
	media.AltText, media.Description, media.Status = nullableString(alt), nullableString(desc), status.String
	media.CreatedAt = timestampOrEmpty(created)
	return id, owner, media, nil
}

const directExactMessageSQL = `SELECT dm.message_id,dm.conversation_id,dm.sender_id,dm.content,dm.is_deleted,
dm.created_at,dm.updated_at,dm.edited_at,dm.deleted_at,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,
u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,fn_get_user_relationship(:viewer_id,u.user_id) AS relation
FROM n_direct_messages dm JOIN v_user_profile_public u ON u.user_id=dm.sender_id
WHERE dm.conversation_id=:conversation_id AND dm.message_id=:message_id AND dm.is_deleted=0`

func readDirectExactMessage(ctx context.Context, tx *sql.Tx, actor, conversation, message int64, storage StorageURLPolicy) (DirectMessage, error) {
	result, err := scanDirectMessage(tx.QueryRowContext(ctx, directExactMessageSQL, sql.Named("viewer_id", actor),
		sql.Named("conversation_id", conversation), sql.Named("message_id", message)), actor)
	if errors.Is(err, sql.ErrNoRows) {
		return DirectMessage{}, errDirectMessageMissing
	}
	if err != nil || result.ID != message || result.ConversationID != conversation || result.IsDeleted {
		return DirectMessage{}, errSessionStore
	}
	if result.Author.AvatarURL, err = normalizeAvatarURL(storage, result.Author.AvatarURL); err != nil {
		return DirectMessage{}, errSessionStore
	}
	items := []DirectMessage{result}
	if err := loadDirectMessageExtras(ctx, tx, actor, items, false); err != nil {
		return DirectMessage{}, err
	}
	return items[0], nil
}

func (s OracleSessions) GetDirectMessage(ctx context.Context, actor, conversation, message int64, storage StorageURLPolicy) (DirectMessage, error) {
	conn, err := s.directExtrasConnection(ctx)
	if err != nil {
		return DirectMessage{}, err
	}
	defer conn.Close()
	return getDirectMessageOn(ctx, conn, actor, conversation, message, storage)
}

type directTxBeginner interface {
	BeginTx(context.Context, *sql.TxOptions) (*sql.Tx, error)
}

func getDirectMessageOn(ctx context.Context, connection directTxBeginner, actor, conversation, message int64, storage StorageURLPolicy) (DirectMessage, error) {
	tx, err := connection.BeginTx(ctx, nil)
	if err != nil {
		return DirectMessage{}, errSessionStore
	}
	defer tx.Rollback()
	var found int64
	err = tx.QueryRowContext(ctx, directHistoryAccessSQL, sql.Named("conversation_id", conversation), sql.Named("user_id", actor)).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return DirectMessage{}, errDirectConversationForbidden
	}
	if err != nil || found != conversation {
		return DirectMessage{}, errSessionStore
	}
	result, err := readDirectExactMessage(ctx, tx, actor, conversation, message, storage)
	if err != nil {
		return DirectMessage{}, err
	}
	if err := tx.Commit(); err != nil {
		return DirectMessage{}, errSessionStore
	}
	return result, nil
}
