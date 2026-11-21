package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type chatChannel struct {
	ID          int64              `json:"channel_id"`
	GroupID     int64              `json:"group_id"`
	Name        string             `json:"name"`
	Type        string             `json:"type"`
	Category    string             `json:"category"`
	Position    int64              `json:"position"`
	Private     bool               `json:"is_private"`
	Muted       bool               `json:"is_muted_by_me"`
	UnreadCount int64              `json:"unread_count"`
	LastMessage *directLastMessage `json:"last_message"`
	CreatedAt   string             `json:"created_at"`
	UpdatedAt   string             `json:"updated_at"`
	CanManage   bool               `json:"can_manage"`
}

type chatChannelListStore interface {
	ListChatChannels(context.Context, int64, int64) ([]chatChannel, error)
}

var errChatGroupForbidden = errors.New("group chat inaccessible")

const chatGroupMembershipSQL = `SELECT CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END
FROM n_group_members gm JOIN n_groups g ON g.group_id=gm.group_id
WHERE gm.user_id=:user_id AND gm.group_id=:group_id AND gm.status IN ('active','muted')
AND g.is_active=1 AND g.is_deleted=0`

const countChatChannelsSQL = `SELECT COUNT(*) FROM n_chat_channels WHERE group_id=:group_id AND is_deleted=0`
const lockChatGroupSQL = `SELECT owner_id FROM n_groups
WHERE group_id=:group_id AND is_active=1 AND is_deleted=0 FOR UPDATE`
const insertDefaultChatChannelSQL = `INSERT INTO n_chat_channels
(channel_id,group_id,name,channel_type,category,position,created_by)
VALUES (seq_chat_channel_id.NEXTVAL,:group_id,:name,:channel_type,:category,:position,:created_by)`

const chatChannelsSelectSQL = `SELECT c.channel_id,c.group_id,c.name,c.channel_type,c.category,c.position,
c.is_private,c.created_at,c.updated_at,CASE WHEN cm.user_id IS NULL THEN 0 ELSE 1 END,
CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END,
(SELECT COUNT(*) FROM n_chat_messages m
 LEFT JOIN n_chat_channel_reads r ON r.channel_id=c.channel_id AND r.user_id=:user_id
 WHERE m.channel_id=c.channel_id AND m.is_deleted=0 AND m.message_id>NVL(r.last_read_message_id,0)),
lm.message_id,lm.content,COALESCE(lu.display_name,lu.username),lm.created_at
FROM n_chat_channels c
JOIN n_groups g ON g.group_id=c.group_id AND g.is_active=1 AND g.is_deleted=0
JOIN n_group_members gm ON gm.group_id=c.group_id AND gm.user_id=:user_id AND gm.status IN ('active','muted')
LEFT JOIN n_chat_channel_mutes cm ON cm.channel_id=c.channel_id AND cm.user_id=:user_id
LEFT JOIN n_chat_messages lm ON lm.message_id=c.last_message_id AND lm.channel_id=c.channel_id AND lm.is_deleted=0
LEFT JOIN n_users lu ON lu.user_id=lm.author_id
WHERE c.group_id=:group_id AND c.is_deleted=0 AND (c.is_private=0 OR gm.role IN ('owner','admin','moderator'))`

const listChatChannelsSQL = chatChannelsSelectSQL + `
ORDER BY c.category ASC,c.position ASC,c.created_at ASC,c.channel_id ASC`

const chatChannelByIDSQL = chatChannelsSelectSQL + ` AND c.channel_id=:channel_id`

func scanChatChannel(row notificationScanner) (chatChannel, error) {
	var channel chatChannel
	var category, preview, author sql.NullString
	var private, muted, canManage int64
	var lastID sql.NullInt64
	var created, updated, lastAt sql.NullTime
	err := row.Scan(&channel.ID, &channel.GroupID, &channel.Name, &channel.Type, &category, &channel.Position,
		&private, &created, &updated, &muted, &canManage, &channel.UnreadCount, &lastID, &preview, &author, &lastAt)
	if err != nil {
		return chatChannel{}, err
	}
	switch channel.Type {
	case "text", "announcement", "voice", "video":
	default:
		return chatChannel{}, errSessionStore
	}
	channel.Category = "文字频道"
	if category.Valid {
		channel.Category = category.String
	}
	channel.Private, channel.Muted, channel.CanManage = private == 1, muted == 1, canManage == 1
	if date := profileDate(created); date != nil {
		channel.CreatedAt = *date
	}
	if date := profileDate(updated); date != nil {
		channel.UpdatedAt = *date
	}
	if lastID.Valid && lastID.Int64 > 0 {
		channel.LastMessage = &directLastMessage{ID: lastID.Int64, Content: preview.String, AuthorName: author.String}
		if date := profileDate(lastAt); date != nil {
			channel.LastMessage.CreatedAt = *date
		}
	}
	return channel, nil
}

func (s OracleSessions) ListChatChannels(ctx context.Context, user, group int64) ([]chatChannel, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, errSessionStore
	}
	defer tx.Rollback()
	userBind, groupBind := sql.Named("user_id", user), sql.Named("group_id", group)
	var canManage, total int64
	readMembership := func() error {
		err := tx.QueryRowContext(ctx, chatGroupMembershipSQL, userBind, groupBind).Scan(&canManage)
		if errors.Is(err, sql.ErrNoRows) {
			return errChatGroupForbidden
		}
		if err != nil {
			return errSessionStore
		}
		return nil
	}
	if err := readMembership(); err != nil {
		return nil, err
	}
	if err := tx.QueryRowContext(ctx, countChatChannelsSQL, groupBind).Scan(&total); err != nil {
		return nil, errSessionStore
	}
	if total == 0 {
		var owner int64
		err := tx.QueryRowContext(ctx, lockChatGroupSQL, groupBind).Scan(&owner)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, errChatGroupForbidden
		}
		if err != nil {
			return nil, errSessionStore
		}
		if err := readMembership(); err != nil {
			return nil, err
		}
		if err := tx.QueryRowContext(ctx, countChatChannelsSQL, groupBind).Scan(&total); err != nil {
			return nil, errSessionStore
		}
		if total == 0 {
			for _, item := range []struct {
				name, kind, category string
				position             int64
			}{{"公告板", "announcement", "公告", 10}, {"综合讨论", "text", "文字频道", 20}} {
				result, err := tx.ExecContext(ctx, insertDefaultChatChannelSQL, groupBind, sql.Named("name", item.name),
					sql.Named("channel_type", item.kind), sql.Named("category", item.category),
					sql.Named("position", item.position), sql.Named("created_by", owner))
				if err != nil {
					return nil, errSessionStore
				}
				if n, err := result.RowsAffected(); err != nil || n != 1 {
					return nil, errSessionStore
				}
			}
		}
	}
	rows, err := tx.QueryContext(ctx, listChatChannelsSQL, userBind, groupBind)
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	items := make([]chatChannel, 0)
	for rows.Next() {
		channel, err := scanChatChannel(rows)
		if err != nil {
			return nil, errSessionStore
		}
		items = append(items, channel)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, errSessionStore
	}
	if len(items) == 0 {
		if err := readMembership(); err != nil {
			return nil, err
		}
	}
	if tx.Commit() != nil {
		return nil, errSessionStore
	}
	return items, nil
}

func chatChannelsRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) bool {
	if r.Method != http.MethodGet {
		return false
	}
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/groups/")
	if !ok {
		return false
	}
	id, ok := strings.CutSuffix(path, "/channels")
	if !ok || id == "" || strings.Contains(id, "/") {
		return false
	}
	user, group, ok := interactionIdentity(w, r, codec, repository, id)
	if !ok {
		return true
	}
	store, ok := repository.(chatChannelListStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	items, err := store.ListChatChannels(r.Context(), user, group)
	switch {
	case errors.Is(err, errChatGroupForbidden):
		respond(w, 403, 40301, "无权访问该群组聊天", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		if items == nil {
			items = []chatChannel{}
		}
		respond(w, 200, 200, "success", items)
	}
	return true
}
