package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type chatMessage struct {
	ID        int64          `json:"message_id"`
	ChannelID int64          `json:"channel_id"`
	GroupID   int64          `json:"group_id"`
	Kind      string         `json:"message_type"`
	Content   string         `json:"content"`
	Author    PublicUser     `json:"author"`
	Reply     *chatReply     `json:"reply_to"`
	Media     []PostMedia    `json:"media"`
	Reactions []chatReaction `json:"reactions"`
	Pinned    bool           `json:"is_pinned"`
	Deleted   bool           `json:"is_deleted"`
	CanDelete bool           `json:"can_delete"`
	CanPin    bool           `json:"can_pin"`
	CreatedAt string         `json:"created_at"`
	UpdatedAt string         `json:"updated_at"`
	EditedAt  *string        `json:"edited_at"`
	DeletedAt *string        `json:"deleted_at"`
}

type chatReply struct {
	ID         int64  `json:"message_id"`
	Content    string `json:"content"`
	AuthorName string `json:"author_name"`
}

type chatReaction struct {
	Emoji   string `json:"emoji"`
	Count   int64  `json:"count"`
	Reacted bool   `json:"reacted_by_me"`
}

type chatMessageHistoryStore interface {
	ListChatMessages(context.Context, int64, int64, SessionPage, chatMessageSearch, StorageURLPolicy) ([]chatMessage, int64, error)
}

const chatMessageScopeSQL = `WHERE m.channel_id=:channel_id AND m.is_deleted=0`
const chatMessageCountSQL = `SELECT COUNT(*) FROM n_chat_messages m
JOIN v_user_profile_public u ON u.user_id=m.author_id
` + chatMessageScopeSQL
const chatMessagePageSQL = `SELECT * FROM (
  SELECT m.message_id,m.channel_id,m.group_id,m.author_id AS user_id,m.message_type,m.content,
m.is_pinned,m.is_deleted,m.created_at,m.updated_at,m.edited_at,m.deleted_at,
u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,
u.followers_count,u.following_count,u.posts_count,u.likes_count,
fn_get_user_relationship(:viewer_id,u.user_id) AS relation,
rm.message_id AS reply_id,rm.content AS reply_content,COALESCE(ru.display_name,ru.username) AS reply_author_name,
  ROW_NUMBER() OVER (ORDER BY m.created_at DESC,m.message_id DESC) AS rn
  FROM n_chat_messages m
  JOIN v_user_profile_public u ON u.user_id=m.author_id
  LEFT JOIN n_chat_messages rm ON rm.message_id=m.reply_to_message_id AND rm.channel_id=m.channel_id AND rm.is_deleted=0
  LEFT JOIN n_users ru ON ru.user_id=rm.author_id
  ` + chatMessageScopeSQL
const chatMessageByIDSQL = `SELECT m.message_id,m.channel_id,m.group_id,m.author_id AS user_id,m.message_type,m.content,
m.is_pinned,m.is_deleted,m.created_at,m.updated_at,m.edited_at,m.deleted_at,
u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,
u.followers_count,u.following_count,u.posts_count,u.likes_count,
fn_get_user_relationship(:viewer_id,u.user_id) AS relation,
rm.message_id AS reply_id,rm.content AS reply_content,COALESCE(ru.display_name,ru.username) AS reply_author_name
  FROM n_chat_messages m
  JOIN v_user_profile_public u ON u.user_id=m.author_id
  LEFT JOIN n_chat_messages rm ON rm.message_id=m.reply_to_message_id AND rm.channel_id=m.channel_id AND rm.is_deleted=0
  LEFT JOIN n_users ru ON ru.user_id=rm.author_id
WHERE m.channel_id=:channel_id AND m.message_id=:message_id AND m.is_deleted=0`
const chatMessageAccessSQL = `SELECT CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS can_manage
FROM n_chat_channels c JOIN n_groups g ON g.group_id=c.group_id
JOIN n_group_members gm ON gm.group_id=c.group_id AND gm.user_id=:user_id
WHERE c.channel_id=:channel_id AND c.is_deleted=0 AND g.is_active=1 AND g.is_deleted=0
AND gm.status IN ('active','muted') AND (c.is_private=0 OR gm.role IN ('owner','admin','moderator'))`
const chatMessageMediaSQL = `SELECT a.message_id,ma.media_id,ma.media_type,ma.file_name,ma.public_url,ma.file_size,ma.mime_type,
ma.width,ma.height,ma.duration,ma.thumbnail_url,ma.alt_text,ma.description,ma.status,ma.created_at
FROM n_chat_message_media a JOIN n_media_assets ma ON ma.media_id=a.media_id
WHERE a.message_id IN (%s) ORDER BY a.message_id,a.position,a.chat_message_media_id`
const chatMessageReactionsSQL = `SELECT message_id,emoji,COUNT(*) AS reaction_count,
MAX(CASE WHEN user_id=:viewer_id THEN 1 ELSE 0 END) AS reacted_by_me
FROM n_chat_message_reactions WHERE message_id IN (%s)
GROUP BY message_id,emoji ORDER BY message_id,reaction_count DESC,emoji ASC`

func scanChatMessage(row notificationScanner, viewer int64, manage bool) (chatMessage, error) {
	message := chatMessage{Media: []PostMedia{}, Reactions: []chatReaction{}, CanPin: manage}
	var content, username, avatar, display, bio, location, website, relation, replyContent, replyAuthor sql.NullString
	var pinned, deleted, verified, followers, following, posts, likes, replyID sql.NullInt64
	var created, updated, edited, removed sql.NullTime
	author := &message.Author
	err := row.Scan(&message.ID, &message.ChannelID, &message.GroupID, &author.UserID, &message.Kind, &content,
		&pinned, &deleted, &created, &updated, &edited, &removed, &username, &avatar, &display, &bio, &location, &website,
		&verified, &followers, &following, &posts, &likes, &relation, &replyID, &replyContent, &replyAuthor)
	if err != nil {
		return chatMessage{}, err
	}
	if message.Kind != "text" && message.Kind != "system" {
		return chatMessage{}, errSessionStore
	}
	message.Content, message.Pinned, message.Deleted = content.String, pinned.Int64 == 1, deleted.Int64 == 1
	message.CanDelete = manage || author.UserID == viewer
	message.CreatedAt, message.UpdatedAt = timestampOrEmpty(created), timestampOrEmpty(updated)
	message.EditedAt, message.DeletedAt = profileDate(edited), profileDate(removed)
	if replyID.Valid {
		message.Reply = &chatReply{replyID.Int64, replyContent.String, replyAuthor.String}
	}
	author.Username, author.AvatarURL, author.DisplayName = username.String, avatar.String, display.String
	author.Bio, author.Location, author.Website = bio.String, location.String, website.String
	author.IsVerified, author.FollowersCount, author.FollowingCount = verified.Int64, followers.Int64, following.Int64
	author.PostsCount, author.LikesCount, author.OnlineStatus = posts.Int64, likes.Int64, "offline"
	rel := relation.String
	if !relation.Valid {
		rel = "none"
	}
	author.Relationship = SelfRelationship{
		Relation: rel, IsSelf: rel == "self", IsFollowing: rel == "following" || rel == "mutual_follow",
		IsBlocked: rel == "blocked_by", IsBlocking: rel == "blocking",
	}
	return message, nil
}

func timestampOrEmpty(value sql.NullTime) string {
	if date := profileDate(value); date != nil {
		return *date
	}
	return ""
}

func (s OracleSessions) ListChatMessages(ctx context.Context, viewer, channel int64, page SessionPage, search chatMessageSearch, storage StorageURLPolicy) ([]chatMessage, int64, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer tx.Rollback()
	if err := lockChatChannelAccess(ctx, tx, viewer, channel); err != nil {
		return nil, 0, err
	}
	channelBind := sql.Named("channel_id", channel)
	userBind := sql.Named("user_id", viewer)
	var manage, total int64
	if err := tx.QueryRowContext(ctx, chatMessageAccessSQL, userBind, channelBind).Scan(&manage); err != nil {
		return nil, 0, chatChannelAccessError(err)
	}
	predicates, filterBinds := search.predicates("m", "channel_sender")
	binds := append([]any{channelBind}, filterBinds...)
	if err := tx.QueryRowContext(ctx, chatMessageCountSQL+predicates, binds...).Scan(&total); err != nil {
		return nil, 0, errSessionStore
	}
	args := append([]any{sql.Named("viewer_id", viewer)}, binds...)
	args = append(args, sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	items, err := collectChatRows(ctx, tx, chatMessagePageSQL+predicates+chatMessageSearchWindowSQL, args, func(rows *sql.Rows) (chatMessage, error) {
		message, err := scanChatMessage(rows, viewer, manage == 1)
		if err == nil {
			message.Author.AvatarURL, err = normalizeAvatarURL(storage, message.Author.AvatarURL)
		}
		return message, err
	})
	if err != nil {
		return nil, 0, errSessionStore
	}
	if len(items) != 0 {
		if err := loadChatMessageDetails(ctx, tx, viewer, items, storage); err != nil {
			return nil, 0, errSessionStore
		}
		if !search.active() && page.Page == 1 {
			if _, err := tx.ExecContext(ctx, mergeChatReadSQL, channelBind, userBind, sql.Named("message_id", items[len(items)-1].ID)); err != nil {
				return nil, 0, errSessionStore
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}

func collectChatRows[T any](ctx context.Context, tx *sql.Tx, query string, args []any, scan func(*sql.Rows) (T, error)) ([]T, error) {
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]T, 0)
	for rows.Next() {
		value, err := scan(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, value)
	}
	return items, rows.Err()
}

func loadChatMessageDetails(ctx context.Context, tx *sql.Tx, viewer int64, items []chatMessage, storage StorageURLPolicy) error {
	binds := make([]any, 0, len(items))
	placeholders := make([]string, 0, len(items))
	messages := make(map[int64]*chatMessage, len(items))
	for i := range items {
		key := "message_" + strconv.Itoa(i)
		binds = append(binds, sql.Named(key, items[i].ID))
		placeholders = append(placeholders, ":"+key)
		messages[items[i].ID] = &items[i]
	}
	in := strings.Join(placeholders, ",")
	_, err := collectChatRows(ctx, tx, fmt.Sprintf(chatMessageMediaSQL, in), binds, func(rows *sql.Rows) (struct{}, error) {
		var id int64
		asset, err := scanPostMedia(rows, &id)
		if err != nil {
			return struct{}{}, err
		}
		message := messages[id]
		if message == nil {
			return struct{}{}, errSessionStore
		}
		if err := normalizePostMedia(storage, &asset); err != nil {
			return struct{}{}, err
		}
		message.Media = append(message.Media, asset)
		return struct{}{}, nil
	})
	if err != nil {
		return err
	}
	args := append([]any{sql.Named("viewer_id", viewer)}, binds...)
	_, err = collectChatRows(ctx, tx, fmt.Sprintf(chatMessageReactionsSQL, in), args, func(rows *sql.Rows) (struct{}, error) {
		var id, reacted int64
		var reaction chatReaction
		if err := rows.Scan(&id, &reaction.Emoji, &reaction.Count, &reacted); err != nil {
			return struct{}{}, err
		}
		message := messages[id]
		if message == nil {
			return struct{}{}, errSessionStore
		}
		reaction.Reacted = reacted == 1
		message.Reactions = append(message.Reactions, reaction)
		return struct{}{}, nil
	})
	return err
}

func chatMessageRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/channels/")
	raw, matched := strings.CutSuffix(path, "/messages")
	if (r.Method != http.MethodGet && r.Method != http.MethodPost) || !ok || !matched || raw == "" || strings.Contains(raw, "/") {
		return false
	}
	user, channel, valid := interactionIdentity(w, r, codec, repository, raw)
	if !valid {
		return true
	}
	if r.Method == http.MethodPost {
		sendChatMessage(w, r, repository, config, user, channel)
		return true
	}
	store, ok := repository.(chatMessageHistoryStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	query := parseSessionQuery(r.URL.RawQuery)
	page := sessionPagination(query)
	search, valid := parseChatMessageSearch(r.URL.RawQuery)
	if !valid {
		respond(w, 400, 40001, "消息搜索参数错误", nil)
		return true
	}
	items, total, err := store.ListChatMessages(r.Context(), user, channel, page, search, config.Storage)
	switch {
	case errors.Is(err, errChatGroupForbidden):
		respond(w, 403, 40301, "无权访问该聊天频道", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		if items == nil {
			items = []chatMessage{}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"code": 200, "message": "success", "data": items,
			"meta": map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)},
		})
	}
	return true
}
