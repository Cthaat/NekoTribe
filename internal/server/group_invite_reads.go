package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupInviteSummary struct {
	ID          int64   `json:"group_id"`
	Name        string  `json:"name"`
	Slug        string  `json:"slug"`
	Description string  `json:"description"`
	AvatarURL   *string `json:"avatar_url"`
	Privacy     string  `json:"privacy"`
	MemberCount int64   `json:"member_count"`
}

type groupInviteItem struct {
	ID        int64              `json:"invite_id"`
	Code      *string            `json:"invite_code"`
	Status    string             `json:"status"`
	Message   *string            `json:"message"`
	MaxUses   *int64             `json:"max_uses"`
	UsedCount int64              `json:"used_count"`
	ExpiresAt *string            `json:"expires_at"`
	CreatedAt string             `json:"created_at"`
	Group     groupInviteSummary `json:"group"`
	Inviter   PublicUser         `json:"inviter"`
	Invitee   *PublicUser        `json:"invitee"`
	Valid     bool               `json:"is_valid"`
}

type groupInvitePreview struct {
	Group   groupDetail `json:"group"`
	Inviter PublicUser  `json:"inviter"`
	Message *string     `json:"message"`
	Valid   bool        `json:"is_valid"`
}

type groupInviteReadStore interface {
	GroupInvites(context.Context, int64, int64, SessionPage, string, StorageURLPolicy) ([]groupInviteItem, int64, error)
	GroupInvitePreview(context.Context, int64, string, StorageURLPolicy) (groupInvitePreview, error)
}

const groupInviteListSQL = `SELECT allowed,total,invite_id,invite_code,status,message,max_uses,used_count,
 expires_at,created_at,group_id,group_name,group_slug,group_description,group_avatar_url,group_privacy,
 group_member_count,inviter_id,invitee_id,is_valid
FROM (
WITH invite_scope AS (
 SELECT g.group_id,g.description,
 CASE WHEN m.status='active' AND m.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS allowed
 FROM n_groups g LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:viewer_id
 WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
), eligible AS (
 SELECT v.invite_id,v.invite_code,v.status,v.message,v.max_uses,v.used_count,v.expires_at,v.created_at,
 v.group_id,v.group_name,v.group_slug,s.description AS group_description,v.group_avatar_url,v.group_privacy,
 v.group_member_count,v.inviter_id,v.invitee_id,v.is_valid,
 ROW_NUMBER() OVER (ORDER BY v.created_at DESC,v.invite_id DESC) AS rn
 FROM invite_scope s JOIN v_group_invite_details v ON v.group_id=s.group_id
 WHERE s.allowed=1 AND (:status_filter IS NULL OR v.status=:status_filter)
)
SELECT s.allowed,t.total,e.invite_id,e.invite_code,e.status,e.message,e.max_uses,e.used_count,
 e.expires_at,e.created_at,e.group_id,e.group_name,e.group_slug,e.group_description,e.group_avatar_url,
 e.group_privacy,e.group_member_count,e.inviter_id,e.invitee_id,e.is_valid,e.rn
FROM invite_scope s CROSS JOIN (SELECT COUNT(*) AS total FROM eligible) t
LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row
) ORDER BY rn`
const groupInvitePreviewSQL = `SELECT v.group_id,v.inviter_id,v.message,
 CASE WHEN g.is_active=1 AND g.is_deleted=0 THEN v.is_valid ELSE 0 END AS is_valid
FROM v_group_invite_details v JOIN n_groups g ON g.group_id=v.group_id
WHERE v.invite_code=:invite_code AND (v.invitee_id IS NULL OR v.invitee_id=:viewer_id)
ORDER BY v.invite_id ASC FETCH FIRST 2 ROWS ONLY`

var groupInviteCodePattern = regexp.MustCompile("^[a-zA-Z0-9]{1,32}$")

func inviteCodeFromPath(raw string) (string, bool) {
	decoded, err := url.PathUnescape(raw)
	code := strings.TrimFunc(decoded, jsTrimSpace)
	return strings.ToUpper(code), err == nil && groupInviteCodePattern.MatchString(code)
}

func (s OracleSessions) invitePublicUser(ctx context.Context, viewer, target int64, storage StorageURLPolicy) (PublicUser, error) {
	return readGroupPublicUser(ctx, s.DB, viewer, target, storage)
}

func readGroupPublicUser(ctx context.Context, db publicProfileQueryer, viewer, target int64, storage StorageURLPolicy) (PublicUser, error) {
	profile, found, err := readPublicProfile(ctx, db, viewer, target)
	if err != nil {
		return PublicUser{}, err
	}
	if !found {
		return PublicUser{}, errGroupMemberProfileMissing
	}
	profile.AvatarURL, err = normalizeAvatarURL(storage, profile.AvatarURL)
	if err != nil {
		return PublicUser{}, errSessionStore
	}
	return profile, nil
}

func (s OracleSessions) GroupInvites(ctx context.Context, viewer, group int64, page SessionPage, status string, storage StorageURLPolicy) ([]groupInviteItem, int64, error) {
	rows, err := s.DB.QueryContext(ctx, groupInviteListSQL, sql.Named("viewer_id", viewer), sql.Named("group_id", group), sql.Named("start_row", page.Start), sql.Named("end_row", page.End), sql.Named("status_filter", status))
	if err != nil {
		return nil, 0, errSessionStore
	}
	return s.readGroupInvites(ctx, viewer, rows, storage)
}

func (s OracleSessions) readGroupInvites(ctx context.Context, viewer int64, rows *sql.Rows, storage StorageURLPolicy) ([]groupInviteItem, int64, error) {
	var err error
	defer rows.Close()
	items := []groupInviteItem{}
	var total int64
	found := false
	for rows.Next() {
		found = true
		var access int
		var id, maxUses, used, groupID, memberCount, inviter, invitee, valid sql.NullInt64
		var code, status, message, name, slug, desc, avatar, privacy sql.NullString
		var expires, created sql.NullTime
		if rows.Scan(&access, &total, &id, &code, &status, &message, &maxUses, &used, &expires, &created,
			&groupID, &name, &slug, &desc, &avatar, &privacy, &memberCount, &inviter, &invitee, &valid) != nil {
			return nil, 0, errSessionStore
		}
		if access != 1 {
			return nil, 0, &groupMembershipFailure{422, "无权查看群组邀请"}
		}
		if !id.Valid {
			continue
		}
		item := groupInviteItem{ID: id.Int64, Code: nullableString(code), Status: status.String, Message: nullableString(message), UsedCount: used.Int64,
			ExpiresAt: profileDate(expires), CreatedAt: timestampOrEmpty(created), Valid: valid.Int64 == 1,
			Group:   groupInviteSummary{groupID.Int64, name.String, slug.String, desc.String, nullableString(avatar), privacy.String, memberCount.Int64},
			Inviter: PublicUser{UserID: inviter.Int64}}
		if maxUses.Valid {
			item.MaxUses = &maxUses.Int64
		}
		if invitee.Valid {
			item.Invitee = &PublicUser{UserID: invitee.Int64}
		}
		items = append(items, item)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, 0, errSessionStore
	}
	if !found {
		return nil, 0, errGroupDetailMissing
	}
	for i := range items {
		item := &items[i]
		item.Inviter, err = s.invitePublicUser(ctx, viewer, item.Inviter.UserID, storage)
		if err != nil {
			return nil, 0, err
		}
		if item.Invitee != nil {
			u, err := s.invitePublicUser(ctx, viewer, item.Invitee.UserID, storage)
			if err != nil {
				return nil, 0, err
			}
			item.Invitee = &u
		}
	}
	return items, total, nil
}

func (s OracleSessions) GroupInvitePreview(ctx context.Context, viewer int64, code string, storage StorageURLPolicy) (groupInvitePreview, error) {
	rows, err := s.DB.QueryContext(ctx, groupInvitePreviewSQL, sql.Named("invite_code", code), sql.Named("viewer_id", viewer))
	if err != nil {
		return groupInvitePreview{}, errSessionStore
	}
	defer rows.Close()
	if !rows.Next() {
		if rows.Err() != nil {
			return groupInvitePreview{}, errSessionStore
		}
		return groupInvitePreview{}, &groupMembershipFailure{404, "邀请码不存在"}
	}
	var group, inviter, valid int64
	var msg sql.NullString
	if rows.Scan(&group, &inviter, &msg, &valid) != nil {
		return groupInvitePreview{}, errSessionStore
	}
	duplicate := rows.Next()
	if rows.Err() != nil || rows.Close() != nil {
		return groupInvitePreview{}, errSessionStore
	}
	if duplicate || valid != 1 {
		return groupInvitePreview{}, &groupMembershipFailure{422, "邀请码无效或已过期"}
	}
	detail, err := s.GroupDetail(ctx, viewer, groupLookup{id: group}, storage)
	if err != nil {
		return groupInvitePreview{}, err
	}
	if detail.Active != 1 {
		return groupInvitePreview{}, &groupMembershipFailure{422, "邀请码无效或已过期"}
	}
	profile, err := s.invitePublicUser(ctx, viewer, inviter, storage)
	if err != nil {
		return groupInvitePreview{}, err
	}
	return groupInvitePreview{Group: detail, Inviter: profile, Message: nullableString(msg), Valid: true}, nil
}

func groupInviteReadError(w http.ResponseWriter, err error) {
	var failure *groupMembershipFailure
	switch {
	case errors.Is(err, errPublishForbidden):
		respond(w, 403, 40301, publishPolicy.Message, nil)
	case errors.As(err, &failure):
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case errors.Is(err, errGroupDetailMissing):
		respond(w, 404, 40401, "群组不存在", nil)
	case errors.Is(err, errGroupOwnerMissing) || errors.Is(err, errGroupMemberProfileMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
}

func groupInviteReadsRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	if !ok || r.Method != http.MethodGet {
		return false
	}
	if raw, match := strings.CutPrefix(path, "invite-codes/"); match && raw != "" && !strings.Contains(raw, "/") {
		viewer, ok := interactionActor(w, r, codec, repo)
		if !ok {
			return true
		}
		code, valid := inviteCodeFromPath(raw)
		if !valid {
			respond(w, 400, 40001, "code 参数错误", nil)
			return true
		}
		store, ok := repo.(groupInviteReadStore)
		if !ok {
			groupInviteReadError(w, errSessionStore)
			return true
		}
		out, err := store.GroupInvitePreview(r.Context(), viewer, code, storage)
		if err != nil {
			groupInviteReadError(w, err)
		} else {
			respond(w, 200, 200, "success", out)
		}
		return true
	}
	id, match := strings.CutSuffix(path, "/invites")
	if !match || id == "" || strings.Contains(id, "/") {
		return false
	}
	viewer, group, valid := interactionIdentity(w, r, codec, repo, id)
	if !valid {
		return true
	}
	store, ok := repo.(groupInviteReadStore)
	if !ok {
		groupInviteReadError(w, errSessionStore)
		return true
	}
	values := parseSessionQuery(r.URL.RawQuery)
	status := values.Get("status")
	if len(values["status"]) > 1 || !validMemberFilter(status, "pending", "accepted", "rejected", "expired") {
		respond(w, 400, 40001, "status 参数错误", nil)
		return true
	}
	page := sessionPagination(values)
	list, total, err := store.GroupInvites(r.Context(), viewer, group, page, status, storage)
	if err != nil {
		groupInviteReadError(w, err)
		return true
	}
	writeGroupInvitePage(w, list, total, page)
	return true
}

func writeGroupInvitePage(w http.ResponseWriter, list []groupInviteItem, total int64, page SessionPage) {
	if list == nil {
		list = []groupInviteItem{}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": list, "meta": map[string]any{
		"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total),
	}})
}
