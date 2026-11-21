package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupPreference struct {
	UserID  int64  `json:"user_id"`
	GroupID int64  `json:"group_id"`
	Enabled bool   `json:"is_enabled"`
	Updated string `json:"updated_at"`
}

type groupAuditItem struct {
	ID              int64       `json:"log_id"`
	GroupID         int64       `json:"group_id"`
	ActorID         int64       `json:"actor_id"`
	Actor           *PublicUser `json:"actor"`
	TargetUserID    *int64      `json:"target_user_id"`
	TargetUser      *PublicUser `json:"target_user"`
	TargetPostID    *int64      `json:"target_post_id"`
	TargetCommentID *int64      `json:"target_comment_id"`
	Action          string      `json:"action"`
	Details         any         `json:"details"`
	IP              *string     `json:"ip_address"`
	Created         string      `json:"created_at"`
}

type groupAdminStore interface {
	GroupNotificationPreference(context.Context, int64, int64, *bool) (groupPreference, error)
	GroupAuditLogs(context.Context, int64, int64, SessionPage, StorageURLPolicy) ([]groupAuditItem, int64, error)
}

const groupPreferenceSQL = `SELECT g.group_id, m.user_id AS member_id, COALESCE(p.is_enabled,1) AS is_enabled,
  p.updated_at
FROM n_groups g
LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:user_id AND m.status='active'
LEFT JOIN n_group_notification_preferences p ON p.group_id=g.group_id AND p.user_id=m.user_id
WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0`
const saveGroupPreferenceSQL = `MERGE INTO n_group_notification_preferences p
USING (SELECT :user_id AS user_id,:group_id AS group_id,:is_enabled AS is_enabled FROM dual) src
ON (p.user_id=src.user_id AND p.group_id=src.group_id)
WHEN MATCHED THEN UPDATE SET p.is_enabled=src.is_enabled,p.updated_at=SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (user_id,group_id,is_enabled) VALUES (src.user_id,src.group_id,src.is_enabled)`
const groupAuditLogsSQL = `WITH active_group AS (
  SELECT group_id FROM n_groups WHERE group_id=:group_id AND is_active=1 AND is_deleted=0
), allowed_group AS (
  SELECT g.group_id FROM active_group g
  JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:user_id
  WHERE m.status='active' AND m.role IN ('owner','admin','moderator')
), ranked AS (
  SELECT l.log_id,l.group_id,l.actor_id,l.target_user_id,l.target_post_id,l.target_comment_id,l.action,l.details,l.ip_address,l.created_at,
    ROW_NUMBER() OVER (ORDER BY l.created_at DESC,l.log_id DESC) AS rn
  FROM allowed_group g JOIN n_group_audit_logs l ON l.group_id=g.group_id
)
SELECT (SELECT COUNT(*) FROM active_group) AS group_exists,
  (SELECT COUNT(*) FROM allowed_group) AS scope_allowed,t.total,
  r.log_id,r.group_id,r.actor_id,r.target_user_id,r.target_post_id,r.target_comment_id,r.action,r.details,r.ip_address,r.created_at
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn`

func readGroupPreference(ctx context.Context, db publicProfileQueryer, viewer, group int64, denied string) (groupPreference, error) {
	var result groupPreference
	var member sql.NullInt64
	var flag int64
	var updated sql.NullTime
	err := db.QueryRowContext(ctx, groupPreferenceSQL, sql.Named("user_id", viewer), sql.Named("group_id", group)).
		Scan(&result.GroupID, &member, &flag, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return result, errGroupDetailMissing
	}
	if err != nil {
		return result, errSessionStore
	}
	if !member.Valid {
		return result, &groupMembershipFailure{422, denied}
	}
	result.UserID, result.Enabled, result.Updated = member.Int64, flag == 1, groupContentDate(updated)
	return result, nil
}

func (s OracleSessions) GroupNotificationPreference(ctx context.Context, viewer, group int64, enabled *bool) (groupPreference, error) {
	if enabled == nil {
		result, err := readGroupPreference(ctx, s.DB, viewer, group, "只有群组成员可以查看通知设置")
		if err == nil && result.Updated == "" {
			result.Updated = time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
		}
		return result, err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return groupPreference{}, errSessionStore
	}
	defer tx.Rollback()
	gb, user := sql.Named("group_id", group), sql.Named("user_id", viewer)
	var locked int64
	err = tx.QueryRowContext(ctx, lockGroupContentSQL, gb).Scan(&locked)
	if errors.Is(err, sql.ErrNoRows) {
		return groupPreference{}, errGroupDetailMissing
	}
	if err != nil {
		return groupPreference{}, errSessionStore
	}
	denied := "只有群组成员可以修改通知设置"
	if _, err := readGroupPreference(ctx, tx, viewer, group, denied); err != nil {
		return groupPreference{}, err
	}
	flag := 0
	if *enabled {
		flag = 1
	}
	if writeOneChatRow(ctx, tx, saveGroupPreferenceSQL, user, gb, sql.Named("is_enabled", flag)) != nil {
		return groupPreference{}, errSessionStore
	}
	result, err := readGroupPreference(ctx, tx, viewer, group, denied)
	if err != nil || result.Enabled != *enabled || tx.Commit() != nil {
		return groupPreference{}, errSessionStore
	}
	return result, nil
}

type groupAuditRow struct {
	id, group, actor, target, post, comment sql.NullInt64
	action, detail, ip                      sql.NullString
	created                                 sql.NullTime
}

func (s OracleSessions) GroupAuditLogs(ctx context.Context, viewer, group int64, page SessionPage, storage StorageURLPolicy) ([]groupAuditItem, int64, error) {
	rows, err := s.DB.QueryContext(ctx, groupAuditLogsSQL, sql.Named("user_id", viewer), sql.Named("group_id", group),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	var present, allowed, total int64
	var records []groupAuditRow
	for rows.Next() {
		var r groupAuditRow
		if rows.Scan(&present, &allowed, &total, &r.id, &r.group, &r.actor, &r.target, &r.post, &r.comment, &r.action, &r.detail, &r.ip, &r.created) != nil {
			return nil, 0, errSessionStore
		}
		if r.id.Valid {
			records = append(records, r)
		}
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, 0, errSessionStore
	}
	if present != 1 {
		return nil, 0, errGroupDetailMissing
	}
	if allowed != 1 {
		return nil, 0, &groupMembershipFailure{422, "无权查看审计日志"}
	}

	profiles := make(map[int64]*PublicUser)
	profile := func(id int64) (*PublicUser, error) {
		if id == 0 {
			return nil, nil
		}
		if value, ok := profiles[id]; ok {
			return value, nil
		}
		value, err := readGroupPublicUser(ctx, s.DB, viewer, id, storage)
		if errors.Is(err, errGroupMemberProfileMissing) {
			profiles[id] = nil
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		profiles[id] = &value
		return &value, nil
	}
	items := make([]groupAuditItem, 0, len(records))
	for _, r := range records {
		actor, err := profile(r.actor.Int64)
		if err != nil {
			return nil, 0, err
		}
		target, err := profile(r.target.Int64)
		if err != nil {
			return nil, 0, err
		}
		var details any
		if r.detail.String != "" {
			if json.Valid([]byte(r.detail.String)) {
				details = json.RawMessage(r.detail.String)
			} else {
				details = r.detail.String
			}
		}
		items = append(items, groupAuditItem{
			ID: r.id.Int64, GroupID: r.group.Int64, ActorID: r.actor.Int64, Actor: actor, TargetUserID: nullableInt(r.target), TargetUser: target,
			TargetPostID: nullableInt(r.post), TargetCommentID: nullableInt(r.comment), Action: r.action.String, Details: details, IP: nullableString(r.ip), Created: groupContentDate(r.created),
		})
	}
	return items, total, nil
}

func groupAdminRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	id, route, matched := strings.Cut(path, "/")
	isAudit := route == "audit-logs" && r.Method == http.MethodGet
	isPreference := route == "notification-preference" && (r.Method == http.MethodGet || r.Method == http.MethodPut)
	if !ok || !matched || !(isAudit || isPreference) {
		return false
	}
	viewer, group, valid := interactionIdentity(w, r, codec, repo, id)
	if !valid {
		return true
	}
	var enabled *bool
	if r.Method == http.MethodPut {
		raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		if err != nil || len(raw) > 1<<20 {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		var object map[string]json.RawMessage
		if json.Unmarshal(raw, &object) != nil || object == nil {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		var value any
		_ = json.Unmarshal(object["is_enabled"], &value)
		flag := false
		switch v := value.(type) {
		case bool:
			flag = v
		case float64:
			flag = v == 1
		case string:
			switch strings.ToLower(v) {
			case "1", "true", "yes":
				flag = true
			}
		}
		enabled = &flag
	}
	store, ok := repo.(groupAdminStore)
	if !ok {
		groupInviteReadError(w, errSessionStore)
		return true
	}
	if isPreference {
		result, err := store.GroupNotificationPreference(r.Context(), viewer, group, enabled)
		if err != nil {
			groupInviteReadError(w, err)
			return true
		}
		message := "success"
		if enabled != nil {
			message = "group notification preference updated"
		}
		respond(w, 200, 200, message, result)
		return true
	}
	page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
	items, total, err := store.GroupAuditLogs(r.Context(), viewer, group, page, storage)
	if err != nil {
		groupInviteReadError(w, err)
		return true
	}
	meta := map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": items, "meta": meta})
	return true
}
