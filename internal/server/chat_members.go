package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type chatMember struct {
	ID           int64   `json:"user_id"`
	Username     string  `json:"username"`
	DisplayName  string  `json:"display_name"`
	AvatarURL    *string `json:"avatar_url"`
	Role         string  `json:"role"`
	Status       string  `json:"status"`
	OnlineStatus string  `json:"online_status"`
	LastSeenAt   *string `json:"last_seen_at"`
}

type chatMemberStore interface {
	ListChatMembers(context.Context, int64, int64, StorageURLPolicy) ([]chatMember, error)
}

const chatMemberListSQL = `SELECT gm.user_id,gm.username,COALESCE(gm.nickname,gm.display_name,gm.username) AS display_name,
gm.avatar_url,gm.role,gm.status,
CASE WHEN NVL(us.show_online_status,1)=0 THEN 'hidden'
 WHEN EXISTS (SELECT 1 FROM n_auth_sessions s WHERE s.user_id=gm.user_id
 AND s.revoked_at IS NULL AND s.last_accessed_at>=CURRENT_TIMESTAMP-NUMTODSINTERVAL(90,'SECOND')) THEN 'online'
 ELSE 'offline' END AS online_status,
CASE WHEN NVL(us.show_online_status,1)=0 THEN NULL ELSE
 (SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=gm.user_id AND s.revoked_at IS NULL)
 END AS last_seen_at
FROM n_group_members viewer
JOIN n_groups g ON g.group_id=viewer.group_id AND g.is_active=1 AND g.is_deleted=0
LEFT JOIN v_group_member_details gm ON gm.group_id=g.group_id AND gm.status IN ('active','muted')
LEFT JOIN n_user_settings us ON us.user_id=gm.user_id
WHERE viewer.group_id=:group_id AND viewer.user_id=:user_id AND viewer.status IN ('active','muted')
ORDER BY CASE gm.role WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 WHEN 'moderator' THEN 3 ELSE 4 END,
gm.joined_at ASC,gm.user_id ASC`

func (s OracleSessions) ListChatMembers(ctx context.Context, user, group int64, storage StorageURLPolicy) ([]chatMember, error) {
	rows, err := s.DB.QueryContext(ctx, chatMemberListSQL, sql.Named("group_id", group), sql.Named("user_id", user))
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	items := []chatMember{}
	found := false
	for rows.Next() {
		found = true
		var id sql.NullInt64
		var username, display, avatar, role, status, online sql.NullString
		var seen sql.NullTime
		if err := rows.Scan(&id, &username, &display, &avatar, &role, &status, &online, &seen); err != nil {
			return nil, errSessionStore
		}
		if !id.Valid {
			continue
		}
		item := chatMember{ID: id.Int64, Username: username.String, DisplayName: display.String,
			Role: role.String, Status: status.String, OnlineStatus: "offline"}
		switch online.String {
		case "online", "hidden":
			item.OnlineStatus = online.String
		}
		if item.OnlineStatus != "hidden" {
			item.LastSeenAt = profileDate(seen)
		}
		if avatar.String != "" {
			url, err := normalizeAvatarURL(storage, avatar.String)
			if err != nil {
				return nil, errSessionStore
			}
			item.AvatarURL = &url
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		return nil, errSessionStore
	}
	if !found {
		return nil, errChatGroupForbidden
	}
	return items, nil
}

func chatMembersRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, storage StorageURLPolicy) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/groups/")
	id, matched := strings.CutSuffix(path, "/members")
	if r.Method != http.MethodGet || !ok || !matched || id == "" || strings.Contains(id, "/") {
		return false
	}
	user, group, valid := interactionIdentity(w, r, codec, repository, id)
	if !valid {
		return true
	}
	store, ok := repository.(chatMemberStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	items, err := store.ListChatMembers(r.Context(), user, group, storage)
	switch {
	case errors.Is(err, errChatGroupForbidden):
		respond(w, 403, 40301, "无权访问该群组聊天", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		if items == nil {
			items = []chatMember{}
		}
		respond(w, 200, 200, "success", items)
	}
	return true
}
