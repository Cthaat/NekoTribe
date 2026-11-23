package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type directConversation struct {
	ID          int64              `json:"conversation_id"`
	Participant PublicUser         `json:"participant"`
	UnreadCount int64              `json:"unread_count"`
	LastMessage *directLastMessage `json:"last_message"`
	CreatedAt   string             `json:"created_at"`
	UpdatedAt   string             `json:"updated_at"`
}

type directLastMessage struct {
	ID         int64  `json:"message_id"`
	Content    string `json:"content"`
	AuthorName string `json:"author_name"`
	CreatedAt  string `json:"created_at"`
}

type directConversationStore interface {
	ListDirectConversations(context.Context, int64, int64, SessionPage) ([]directConversation, int64, error)
	CreateDirectConversation(context.Context, int64, int64, StorageURLPolicy) (directConversation, error)
}

const directConversationProjection = `SELECT c.conversation_id,c.created_at,c.updated_at,
p.user_id,p.username,p.avatar_url,p.display_name,p.bio,p.location,p.website,p.is_verified,
p.followers_count,p.following_count,p.posts_count,p.likes_count,
fn_get_user_relationship(:viewer_id,p.user_id) AS relation,
lm.message_id AS last_message_id,lm.content AS last_message_content,
COALESCE(lu.display_name,lu.username) AS last_message_author,lm.created_at AS last_message_at,
(SELECT COUNT(*) FROM n_direct_messages dm
 LEFT JOIN n_direct_conversation_reads r ON r.conversation_id=dm.conversation_id AND r.user_id=:viewer_id
 WHERE dm.conversation_id=c.conversation_id AND dm.sender_id<>:viewer_id
 AND dm.is_deleted=0 AND dm.message_id>NVL(r.last_read_message_id,0)) AS unread_count`

const directConversationFrom = ` FROM n_direct_conversations c
JOIN v_user_profile_public p ON p.user_id=CASE WHEN c.user_low_id=:viewer_id THEN c.user_high_id ELSE c.user_low_id END
LEFT JOIN n_direct_messages lm ON lm.message_id=c.last_message_id AND lm.is_deleted=0
LEFT JOIN n_users lu ON lu.user_id=lm.sender_id
WHERE c.is_deleted=0 AND (c.user_low_id=:viewer_id OR c.user_high_id=:viewer_id)`

const directConversationListSQL = `WITH ranked AS (` +
	directConversationProjection + `,ROW_NUMBER() OVER (ORDER BY NVL(lm.created_at,c.updated_at) DESC,c.conversation_id DESC) AS rn` +
	directConversationFrom + ` AND (:conversation_id=0 OR c.conversation_id=:conversation_id))
SELECT r.conversation_id,r.created_at,r.updated_at,r.user_id,r.username,r.avatar_url,r.display_name,r.bio,r.location,
r.website,r.is_verified,r.followers_count,r.following_count,r.posts_count,r.likes_count,r.relation,
r.last_message_id,r.last_message_content,r.last_message_author,r.last_message_at,r.unread_count,t.total
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row ORDER BY r.rn`

const directConversationPairSQL = `SELECT conversation_id,is_deleted FROM n_direct_conversations
WHERE user_low_id=:low_id AND user_high_id=:high_id`

var errDeletedDirectPair = errors.New("direct conversation pair is deleted")

func scanDirectConversation(row notificationScanner, total *int64) (directConversation, error) {
	var item directConversation
	var created, updated, latest sql.NullTime
	var username, avatar, display, bio, location, website, relation, content, name sql.NullString
	var id, userID, unread, verified, followers, following, posts, likes, lastID sql.NullInt64
	p := &item.Participant
	dest := []any{&id, &created, &updated, &userID, &username, &avatar, &display,
		&bio, &location, &website, &verified, &followers, &following, &posts, &likes, &relation,
		&lastID, &content, &name, &latest, &unread}
	if total != nil {
		dest = append(dest, total)
	}
	if err := row.Scan(dest...); err != nil {
		return directConversation{}, err
	}
	if !id.Valid && total != nil {
		return directConversation{}, nil
	}
	if !id.Valid || !userID.Valid || !unread.Valid {
		return directConversation{}, errSessionStore
	}
	item.ID, p.UserID, item.UnreadCount = id.Int64, userID.Int64, unread.Int64
	p.Username, p.AvatarURL, p.DisplayName = username.String, avatar.String, display.String
	p.Bio, p.Location, p.Website = bio.String, location.String, website.String
	p.IsVerified, p.FollowersCount, p.FollowingCount = verified.Int64, followers.Int64, following.Int64
	p.PostsCount, p.LikesCount = posts.Int64, likes.Int64
	p.OnlineStatus = "offline"
	rel := relation.String
	if rel == "" {
		rel = "none"
	}
	p.Relationship = SelfRelationship{Relation: rel, IsSelf: rel == "self",
		IsFollowing: rel == "following" || rel == "mutual_follow", IsBlocked: rel == "blocked_by", IsBlocking: rel == "blocking"}
	date := func(value sql.NullTime) string {
		if formatted := profileDate(value); formatted != nil {
			return *formatted
		}
		return ""
	}
	item.CreatedAt, item.UpdatedAt = date(created), date(updated)
	if lastID.Valid && lastID.Int64 > 0 {
		item.LastMessage = &directLastMessage{lastID.Int64, directVisibleContent(content.String), name.String, date(latest)}
	}
	return item, nil
}

func (s OracleSessions) ListDirectConversations(ctx context.Context, viewer, conversationID int64, page SessionPage) ([]directConversation, int64, error) {
	viewerBind := sql.Named("viewer_id", viewer)
	var total int64
	rows, err := s.DB.QueryContext(ctx, directConversationListSQL, viewerBind,
		sql.Named("conversation_id", conversationID),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	items := make([]directConversation, 0)
	for rows.Next() {
		item, err := scanDirectConversation(rows, &total)
		if err != nil {
			return nil, 0, errSessionStore
		}
		if item.ID != 0 {
			items = append(items, item)
		}
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}

func (s OracleSessions) CreateDirectConversation(ctx context.Context, sender, target int64, storage StorageURLPolicy) (directConversation, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return directConversation{}, errSessionStore
	}
	defer tx.Rollback()
	if err = checkDirectRecipient(ctx, tx, sender, target); err != nil {
		return directConversation{}, err
	}
	low, high := sql.Named("low_id", min(sender, target)), sql.Named("high_id", max(sender, target))
	var id, deleted int64
	readPair := func() error {
		return tx.QueryRowContext(ctx, directConversationPairSQL, low, high).Scan(&id, &deleted)
	}
	if err = readPair(); errors.Is(err, sql.ErrNoRows) {
		if err = tx.QueryRowContext(ctx, `SELECT seq_direct_conversation_id.NEXTVAL FROM dual`).Scan(&id); err != nil || id < 1 || id > maxSocketID {
			return directConversation{}, errSessionStore
		}
		const insert = `INSERT INTO n_direct_conversations (conversation_id,user_low_id,user_high_id,created_by)
VALUES (:conversation_id,:low_id,:high_id,:sender_id)`
		if _, err = tx.ExecContext(ctx, insert, sql.Named("conversation_id", id), low, high, sql.Named("sender_id", sender)); err != nil {
			// Concurrent inserts are serialized by the unique pair constraint.
			var unique interface{ ErrorCode() string }
			if !errors.As(err, &unique) || unique.ErrorCode() != "ORA-00001" || readPair() != nil {
				return directConversation{}, errSessionStore
			}
		}
	} else if err != nil {
		return directConversation{}, errSessionStore
	}
	if deleted != 0 {
		return directConversation{}, errDeletedDirectPair
	}
	item, err := scanDirectConversation(tx.QueryRowContext(ctx, directConversationProjection+directConversationFrom+
		" AND c.conversation_id=:conversation_id", sql.Named("viewer_id", sender), sql.Named("conversation_id", id)), nil)
	if err != nil {
		return directConversation{}, errSessionStore
	}
	item.Participant.AvatarURL, err = normalizeAvatarURL(storage, item.Participant.AvatarURL)
	if err != nil || tx.Commit() != nil {
		return directConversation{}, errSessionStore
	}
	return item, nil
}

func directConversationsRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	if r.URL.EscapedPath() != "/api/v2/chat/direct-conversations" || r.Method != http.MethodGet && r.Method != http.MethodPost {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	viewer, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	store, ok := repository.(directConversationStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if r.Method == http.MethodPost {
		createDirectConversation(w, r, store, viewer, config.Storage)
		return true
	}
	query := parseSessionQuery(r.URL.RawQuery)
	var conversationID int64
	if values := query["conversation_id"]; len(values) > 0 {
		id, err := strconv.ParseInt(values[0], 10, 64)
		if len(values) != 1 || err != nil || !publicID.MatchString(values[0]) || id > maxSocketID {
			respond(w, 400, 40001, "conversation_id 参数错误", nil)
			return true
		}
		conversationID = id
	}
	page := sessionPagination(query)
	items, total, err := store.ListDirectConversations(r.Context(), viewer, conversationID, page)
	if err == nil {
		for i := range items {
			p := &items[i].Participant
			p.AvatarURL, err = normalizeAvatarURL(config.Storage, p.AvatarURL)
			if err != nil {
				break
			}
		}
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if items == nil {
		items = []directConversation{}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"code": 200, "message": "success", "data": items,
		"meta": map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)},
	})
	return true
}

func createDirectConversation(w http.ResponseWriter, r *http.Request, store directConversationStore, viewer int64, storage StorageURLPolicy) {
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	target, valid := optionalCommentParent(body["target_user_id"])
	if !valid || target == nil {
		respond(w, 400, 40001, "target_user_id 参数错误", nil)
		return
	}
	if *target == viewer {
		respond(w, 400, 40001, "不能给自己发送私信", nil)
		return
	}
	item, err := store.CreateDirectConversation(r.Context(), viewer, *target, storage)
	switch {
	case errors.Is(err, errDirectRecipientMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case errors.Is(err, errDirectBlocked):
		respond(w, 403, 40301, "无法向该用户发送私信", nil)
	case errors.Is(err, errDirectStrangers):
		respond(w, 403, 40301, "对方不接收陌生人私信", nil)
	case errors.Is(err, errDeletedDirectPair):
		respond(w, 409, 40901, "私聊会话已删除", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, "direct conversation ready", item)
	}
}
