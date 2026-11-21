package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type chatGroup struct {
	ID           int64               `json:"group_id"`
	Name         string              `json:"name"`
	AvatarURL    *string             `json:"avatar_url"`
	MemberCount  int64               `json:"member_count"`
	ChannelCount int64               `json:"channel_count"`
	UnreadCount  int64               `json:"unread_count"`
	Membership   chatGroupMembership `json:"membership"`
}

type chatGroupMembership struct {
	IsMember  bool    `json:"is_member"`
	Role      string  `json:"role"`
	Status    string  `json:"status"`
	JoinedAt  *string `json:"joined_at"`
	CanManage bool    `json:"can_manage"`
}

type chatGroupListStore interface {
	ListChatGroups(context.Context, int64, SessionPage) ([]chatGroup, int64, error)
}

const chatGroupMembershipFrom = ` FROM n_group_members gm JOIN n_groups g ON g.group_id=gm.group_id
WHERE gm.user_id=:user_id AND gm.status IN ('active','muted') AND g.is_active=1 AND g.is_deleted=0`

const visibleChatGroupChannel = `c.group_id=r.group_id AND c.is_deleted=0
AND (c.is_private=0 OR r.role IN ('owner','admin','moderator'))`

const chatGroupListSQL = `WITH ranked AS (
 SELECT g.group_id,g.name,g.avatar_url,g.member_count,gm.role,gm.status,gm.joined_at,
 ROW_NUMBER() OVER (ORDER BY g.member_count DESC,g.created_at DESC,g.group_id DESC) AS rn` +
	chatGroupMembershipFrom + `
)
SELECT r.group_id,r.name,r.avatar_url,r.member_count,r.role,r.status,r.joined_at,
 CASE WHEN r.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS can_manage,
 (SELECT COUNT(*) FROM n_chat_channels c WHERE ` + visibleChatGroupChannel + `) AS channel_count,
 (SELECT COUNT(*) FROM n_chat_messages m JOIN n_chat_channels c ON c.channel_id=m.channel_id
  LEFT JOIN n_chat_channel_reads cr ON cr.channel_id=c.channel_id AND cr.user_id=:user_id
  WHERE ` + visibleChatGroupChannel + ` AND m.is_deleted=0 AND m.message_id>NVL(cr.last_read_message_id,0)) AS unread_count,
 t.total
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn`

func (s OracleSessions) ListChatGroups(ctx context.Context, viewer int64, page SessionPage) ([]chatGroup, int64, error) {
	user := sql.Named("user_id", viewer)
	var total int64
	rows, err := s.DB.QueryContext(ctx, chatGroupListSQL, user, sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	items := make([]chatGroup, 0)
	for rows.Next() {
		var item chatGroup
		var id, memberCount sql.NullInt64
		var avatar, name, role, status sql.NullString
		var joined sql.NullTime
		var canManage int64
		member := &item.Membership
		if err := rows.Scan(&id, &name, &avatar, &memberCount, &role, &status,
			&joined, &canManage, &item.ChannelCount, &item.UnreadCount, &total); err != nil {
			return nil, 0, errSessionStore
		}
		if !id.Valid {
			continue
		}
		if !name.Valid || !memberCount.Valid || !role.Valid || !status.Valid {
			return nil, 0, errSessionStore
		}
		item.ID, item.Name, item.MemberCount = id.Int64, name.String, memberCount.Int64
		member.Role, member.Status = role.String, status.String
		if avatar.String != "" {
			item.AvatarURL = &avatar.String
		}
		member.IsMember, member.CanManage, member.JoinedAt = true, canManage == 1, profileDate(joined)
		items = append(items, item)
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}

func chatGroupsRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) bool {
	if r.Method != http.MethodGet || r.URL.EscapedPath() != "/api/v2/chat/groups" {
		return false
	}
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	store, ok := repository.(chatGroupListStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
	items, total, err := store.ListChatGroups(r.Context(), user, page)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if items == nil {
		items = []chatGroup{}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"code": 200, "message": "success", "data": items,
		"meta": map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)},
	})
	return true
}
