package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupMember struct {
	MemberID  int64      `json:"member_id"`
	User      PublicUser `json:"user"`
	Role      string     `json:"role"`
	RoleDesc  string     `json:"role_desc"`
	Status    string     `json:"status"`
	Nickname  *string    `json:"nickname"`
	MuteUntil *string    `json:"mute_until"`
	JoinedAt  string     `json:"joined_at"`
}

type groupMemberRequest struct {
	page         SessionPage
	role, status string
}

type groupMemberStore interface {
	ListGroupMembers(context.Context, int64, int64, groupMemberRequest, StorageURLPolicy) ([]groupMember, int64, error)
}

var (
	errGroupMemberListForbidden  = errors.New("group member list forbidden")
	errGroupMemberProfileMissing = errors.New("group member profile missing")
)

const groupMemberListSQL = `SELECT access_level,total,member_id,user_id,role,role_desc,status,nickname,joined_at,mute_until
FROM (
WITH group_scope AS (
  SELECT g.group_id, CASE
    WHEN viewer.status='banned' THEN 0
    WHEN viewer.status='active' AND viewer.role IN ('owner','admin','moderator') THEN 2
    WHEN g.privacy='public' OR viewer.status IN ('active','muted') THEN 1
    ELSE 0 END AS access_level
  FROM n_groups g
  LEFT JOIN n_group_members viewer ON viewer.group_id=g.group_id AND viewer.user_id=:viewer_id
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
), eligible AS (
  SELECT m.member_id,m.user_id,m.role,m.role_desc,m.status,m.nickname,m.joined_at,
    CASE WHEN s.access_level=2 OR m.user_id=:viewer_id THEN m.mute_until END AS mute_until,
    ROW_NUMBER() OVER (ORDER BY CASE m.role WHEN 'owner' THEN 1 WHEN 'admin' THEN 2
      WHEN 'moderator' THEN 3 ELSE 4 END,m.joined_at ASC,m.member_id ASC) AS rn
  FROM group_scope s
  JOIN v_group_member_details m ON m.group_id=s.group_id
  JOIN v_user_profile_public p ON p.user_id=m.user_id AND p.is_active=1
  WHERE s.access_level>0
    AND (s.access_level=2 OR m.status IN ('active','muted'))
    AND (:role_filter IS NULL OR m.role=:role_filter)
    AND (:status_filter IS NULL OR m.status=:status_filter)
)
SELECT s.access_level,c.total,m.member_id,m.user_id,m.role,m.role_desc,m.status,m.nickname,m.joined_at,m.mute_until,m.rn
FROM group_scope s
CROSS JOIN (SELECT COUNT(*) AS total FROM eligible) c
LEFT JOIN eligible m ON m.rn BETWEEN :start_row AND :end_row
) ORDER BY rn`

func (s OracleSessions) ListGroupMembers(ctx context.Context, viewer, group int64, request groupMemberRequest, storage StorageURLPolicy) ([]groupMember, int64, error) {
	rows, err := s.DB.QueryContext(ctx, groupMemberListSQL,
		sql.Named("viewer_id", viewer), sql.Named("group_id", group),
		sql.Named("role_filter", request.role), sql.Named("status_filter", request.status),
		sql.Named("start_row", request.page.Start), sql.Named("end_row", request.page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()

	items := []groupMember{}
	var total int64
	found := false
	for rows.Next() {
		found = true
		var level int
		var memberID, userID sql.NullInt64
		var role, desc, status, nickname sql.NullString
		var joined, muteUntil sql.NullTime
		if err := rows.Scan(&level, &total, &memberID, &userID, &role, &desc, &status, &nickname, &joined, &muteUntil); err != nil {
			return nil, 0, errSessionStore
		}
		if level == 0 {
			return nil, 0, errGroupMemberListForbidden
		}
		if !memberID.Valid {
			continue
		}
		item := groupMember{MemberID: memberID.Int64, User: PublicUser{UserID: userID.Int64}, Role: role.String,
			RoleDesc: desc.String, Status: status.String, MuteUntil: profileDate(muteUntil)}
		if nickname.Valid && nickname.String != "" {
			item.Nickname = &nickname.String
		}
		if date := profileDate(joined); date != nil {
			item.JoinedAt = *date
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	if !found {
		return nil, 0, errGroupDetailMissing
	}
	if err := rows.Close(); err != nil {
		return nil, 0, errSessionStore
	}

	for i := range items {
		profile, exists, err := s.PublicProfile(ctx, viewer, items[i].User.UserID)
		if err != nil {
			return nil, 0, err
		}
		if !exists {
			return nil, 0, errGroupMemberProfileMissing
		}
		profile.AvatarURL, err = normalizeAvatarURL(storage, profile.AvatarURL)
		if err != nil {
			return nil, 0, errSessionStore
		}
		items[i].User = profile
	}
	return items, total, nil
}

func groupMemberListRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, storage StorageURLPolicy) bool {
	path, prefixed := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	id, matched := strings.CutSuffix(path, "/members")
	if r.Method != http.MethodGet || !prefixed || !matched || id == "" || strings.Contains(id, "/") {
		return false
	}
	viewer, group, valid := interactionIdentity(w, r, codec, repository, id)
	if !valid {
		return true
	}

	values := parseSessionQuery(r.URL.RawQuery)
	request := groupMemberRequest{page: sessionPagination(values), role: values.Get("role"), status: values.Get("status")}
	if len(values["role"]) > 1 || !validMemberFilter(request.role, "owner", "admin", "moderator", "member") {
		respond(w, 400, 40001, "role 参数错误", nil)
		return true
	}
	if len(values["status"]) > 1 || !validMemberFilter(request.status, "pending", "active", "muted", "banned") {
		respond(w, 400, 40001, "status 参数错误", nil)
		return true
	}
	store, ok := repository.(groupMemberStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	items, total, err := store.ListGroupMembers(r.Context(), viewer, group, request, storage)
	switch {
	case errors.Is(err, errGroupDetailMissing):
		respond(w, 404, 40401, "群组不存在", nil)
	case errors.Is(err, errGroupMemberListForbidden):
		respond(w, 403, 40301, "无权查看群组成员", nil)
	case errors.Is(err, errGroupMemberProfileMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		if items == nil {
			items = []groupMember{}
		}
		page := request.page
		meta := map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": items, "meta": meta})
	}
	return true
}

func validMemberFilter(value string, choices ...string) bool {
	if value == "" {
		return true
	}
	for _, choice := range choices {
		if choice == value {
			return true
		}
	}
	return false
}
