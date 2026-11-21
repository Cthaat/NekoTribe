package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type DirectMessage struct {
	ID             int64      `json:"message_id"`
	ConversationID int64      `json:"conversation_id"`
	Content        string     `json:"content"`
	Author         PublicUser `json:"author"`
	IsDeleted      bool       `json:"is_deleted"`
	CanDelete      bool       `json:"can_delete"`
	CreatedAt      string     `json:"created_at"`
	UpdatedAt      string     `json:"updated_at"`
	EditedAt       *string    `json:"edited_at"`
	DeletedAt      *string    `json:"deleted_at"`
}

type directHistoryStore interface {
	ListDirectMessages(context.Context, int64, int64, SessionPage) ([]DirectMessage, int64, error)
}

var errDirectConversationForbidden = errors.New("direct conversation inaccessible")

const directHistoryAccessSQL = `SELECT conversation_id FROM n_direct_conversations
WHERE conversation_id=:conversation_id AND is_deleted=0
  AND (user_low_id=:user_id OR user_high_id=:user_id)
FOR UPDATE`

const directHistoryPageSQL = `SELECT message_id,conversation_id,sender_id,content,is_deleted,
created_at,updated_at,edited_at,deleted_at,username,avatar_url,display_name,bio,location,website,
is_verified,followers_count,following_count,posts_count,likes_count,relation
FROM (
  SELECT dm.message_id,dm.conversation_id,dm.sender_id,dm.content,dm.is_deleted,
    dm.created_at,dm.updated_at,dm.edited_at,dm.deleted_at,
    u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,
    u.followers_count,u.following_count,u.posts_count,u.likes_count,
    fn_get_user_relationship(:viewer_id,u.user_id) AS relation,
    ROW_NUMBER() OVER (ORDER BY dm.created_at DESC,dm.message_id DESC) AS rn
  FROM n_direct_messages dm
  JOIN v_user_profile_public u ON u.user_id=dm.sender_id
  WHERE dm.conversation_id=:conversation_id AND dm.is_deleted=0
)
WHERE rn BETWEEN :start_row AND :end_row
ORDER BY created_at ASC,message_id ASC`

const markDirectReadSQL = `MERGE INTO n_direct_conversation_reads r
USING (SELECT :conversation_id AS conversation_id,:user_id AS user_id,
              :message_id AS message_id FROM dual) src
ON (r.conversation_id=src.conversation_id AND r.user_id=src.user_id)
WHEN MATCHED THEN UPDATE SET
  r.last_read_message_id=GREATEST(NVL(r.last_read_message_id,0),src.message_id),
  r.last_read_at=CURRENT_TIMESTAMP
WHEN NOT MATCHED THEN INSERT (conversation_id,user_id,last_read_message_id,last_read_at)
VALUES (src.conversation_id,src.user_id,src.message_id,CURRENT_TIMESTAMP)`

func scanDirectMessage(row notificationScanner, viewer int64) (DirectMessage, error) {
	var message DirectMessage
	var content, username, avatar, display, bio, location, website, relation sql.NullString
	var deleted, verified, followers, following, posts, likes sql.NullInt64
	var createdAt, updatedAt, editedAt, deletedAt sql.NullTime
	author := &message.Author
	err := row.Scan(&message.ID, &message.ConversationID, &author.UserID,
		&content, &deleted, &createdAt, &updatedAt, &editedAt, &deletedAt,
		&username, &avatar, &display, &bio, &location, &website,
		&verified, &followers, &following, &posts, &likes, &relation)
	if err != nil {
		return DirectMessage{}, err
	}
	message.Content = content.String
	message.IsDeleted = deleted.Int64 != 0
	message.CanDelete = author.UserID == viewer
	if date := profileDate(createdAt); date != nil {
		message.CreatedAt = *date
	}
	if date := profileDate(updatedAt); date != nil {
		message.UpdatedAt = *date
	}
	message.EditedAt, message.DeletedAt = profileDate(editedAt), profileDate(deletedAt)
	author.Username, author.AvatarURL, author.DisplayName = username.String, avatar.String, display.String
	author.Bio, author.Location, author.Website = bio.String, location.String, website.String
	author.IsVerified, author.FollowersCount, author.FollowingCount = verified.Int64, followers.Int64, following.Int64
	author.PostsCount, author.LikesCount = posts.Int64, likes.Int64
	author.OnlineStatus = "offline"
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

func (s OracleSessions) ListDirectMessages(ctx context.Context, viewer, conversation int64, page SessionPage) ([]DirectMessage, int64, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer tx.Rollback()
	conversationBind := sql.Named("conversation_id", conversation)
	viewerBind := sql.Named("user_id", viewer)
	var found, total int64
	err = tx.QueryRowContext(ctx, directHistoryAccessSQL, conversationBind, viewerBind).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, 0, errDirectConversationForbidden
	}
	if err != nil {
		return nil, 0, errSessionStore
	}
	const count = `SELECT COUNT(*) FROM n_direct_messages WHERE conversation_id=:conversation_id AND is_deleted=0`
	if err := tx.QueryRowContext(ctx, count, conversationBind).Scan(&total); err != nil {
		return nil, 0, errSessionStore
	}
	rows, err := tx.QueryContext(ctx, directHistoryPageSQL, sql.Named("viewer_id", viewer),
		conversationBind, sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	items := make([]DirectMessage, 0)
	for rows.Next() {
		message, err := scanDirectMessage(rows, viewer)
		if err != nil {
			return nil, 0, errSessionStore
		}
		items = append(items, message)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, 0, errSessionStore
	}
	if page.Page == 1 && len(items) > 0 {
		if _, err := tx.ExecContext(ctx, markDirectReadSQL, conversationBind, viewerBind,
			sql.Named("message_id", items[len(items)-1].ID)); err != nil {
			return nil, 0, errSessionStore
		}
	}
	if tx.Commit() != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}

func directMessagesRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		return false
	}
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/direct-conversations/")
	if !ok {
		return false
	}
	id, ok := strings.CutSuffix(path, "/messages")
	if !ok || id == "" || strings.Contains(id, "/") {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return true
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return true
	}
	if n, err := repository.Touch(r.Context(), claims); err != nil || n != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return true
	}
	id, err = url.PathUnescape(id)
	if err != nil {
		respond(w, 400, 40001, "conversation_id 参数错误", nil)
		return true
	}
	conversation, err := strconv.ParseInt(id, 10, 64)
	if err != nil || !publicID.MatchString(id) || conversation > maxSocketID {
		respond(w, 400, 40001, "conversation_id 参数错误", nil)
		return true
	}
	if r.Method == http.MethodPost {
		createDirectMessage(w, r, repository, config, claims.UserID, conversation)
		return true
	}
	store, ok := repository.(directHistoryStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
	items, total, err := store.ListDirectMessages(r.Context(), claims.UserID, conversation, page)
	if errors.Is(err, errDirectConversationForbidden) {
		respond(w, 403, 40301, "无权访问该私聊会话", nil)
		return true
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if items == nil {
		items = []DirectMessage{}
	}
	for i := range items {
		author := &items[i].Author
		author.AvatarURL, err = normalizeAvatarURL(config.Storage, author.AvatarURL)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return true
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"code": 200, "message": "success", "data": items,
		"meta": map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)},
	})
	return true
}
