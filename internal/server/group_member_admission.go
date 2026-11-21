package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupAdmissionAction string

const (
	groupApprove groupAdmissionAction = "approve_member"
	groupReject  groupAdmissionAction = "reject_member"
	groupRemove  groupAdmissionAction = "remove_member"
	groupRole    groupAdmissionAction = "change_role"
	groupMute    groupAdmissionAction = "mute_member"
	groupUnmute  groupAdmissionAction = "unmute_member"
)

type groupMemberChange struct {
	action groupAdmissionAction
	role   string
	hours  int
	reason string
}

type groupAdmissionStore interface {
	ManageGroupMember(context.Context, int64, int64, int64, groupMemberChange) (string, error)
}

func (a groupAdmissionAction) approval() bool { return a == groupApprove || a == groupReject }

func (a groupAdmissionAction) permission() string {
	switch a {
	case groupRole:
		return "无权修改角色"
	case groupMute:
		return "无权禁言成员"
	case groupUnmute:
		return "无权解除禁言"
	case groupRemove:
		return "无权移除成员"
	default:
		return "无权审批成员"
	}
}

const groupApprovalTargetSQL = `SELECT user_id,role,status FROM n_group_members WHERE group_id=:group_id AND member_id=:member_id FOR UPDATE`
const groupApproveSQL = `UPDATE n_group_members SET status='active' WHERE group_id=:group_id AND member_id=:member_id AND status='pending' AND role='member'`
const groupRejectSQL = `DELETE FROM n_group_members WHERE group_id=:group_id AND member_id=:member_id AND status='pending' AND role='member'`
const groupAdmissionAuditSQL = `INSERT INTO n_group_audit_logs (group_id,actor_id,target_user_id,action,details) VALUES (:group_id,:actor_id,:target_user_id,:action,:details)`
const groupMemberRoleSQL = `UPDATE n_group_members SET role=:role WHERE group_id=:group_id AND user_id=:user_id AND status IN ('active','muted') AND role<>'owner'`
const groupMuteSQL = `UPDATE n_group_members SET status='muted',mute_until=SYSTIMESTAMP+NUMTODSINTERVAL(:hours,'HOUR'),ban_reason=:reason WHERE group_id=:group_id AND user_id=:user_id AND status IN ('active','muted') AND role<>'owner'`
const groupUnmuteSQL = `UPDATE n_group_members SET status='active',mute_until=NULL,ban_reason=NULL WHERE group_id=:group_id AND user_id=:user_id AND status='muted' AND role<>'owner'`
const groupMuteUntilSQL = `SELECT TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(mute_until,TO_CHAR(SYSTIMESTAMP,'TZH:TZM'))),'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS mute_until FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id`

func groupMemberRank(role string) int {
	switch role {
	case "owner":
		return 4
	case "admin":
		return 3
	case "moderator":
		return 2
	case "member":
		return 1
	default:
		return 0
	}
}

func (s OracleSessions) ManageGroupMember(ctx context.Context, viewer, group, target int64, change groupMemberChange) (string, error) {
	action := change.action
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", errSessionStore
	}
	defer tx.Rollback()
	gb := sql.Named("group_id", group)
	var owner, approval, active, deleted int64
	var privacy string
	err = tx.QueryRowContext(ctx, membershipGroupSQL, gb).Scan(&owner, &privacy, &approval, &active, &deleted)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (active != 1 || deleted != 0) {
		return "", &groupMembershipFailure{404, "群组不存在"}
	}
	if err != nil {
		return "", errSessionStore
	}

	permission := action.permission()
	minimum := 2
	if action == groupRole {
		minimum = 3
	}
	var actorRole, actorStatus string
	err = tx.QueryRowContext(ctx, membershipReadSQL, gb, sql.Named("user_id", viewer)).Scan(&actorRole, &actorStatus)
	rank := groupMemberRank(actorRole)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (actorStatus != "active" || rank < minimum) {
		return "", &groupMembershipFailure{422, permission}
	}
	if err != nil {
		return "", errSessionStore
	}

	userID := target
	var role, status string
	var query string
	var targetBind sql.NamedArg
	if !action.approval() {
		targetBind = sql.Named("user_id", target)
		err = tx.QueryRowContext(ctx, membershipReadSQL, gb, targetBind).Scan(&role, &status)
		query = membershipDeleteSQL
	} else {
		targetBind = sql.Named("member_id", target)
		err = tx.QueryRowContext(ctx, groupApprovalTargetSQL, gb, targetBind).Scan(&userID, &role, &status)
		query = groupRejectSQL
		if action == groupApprove {
			query = groupApproveSQL
		}
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", &groupMembershipFailure{404, "成员不存在"}
	}
	if err != nil {
		return "", errSessionStore
	}
	targetRank := groupMemberRank(role)
	if userID == owner || userID == viewer || targetRank == 0 || targetRank >= rank || status == "banned" {
		return "", &groupMembershipFailure{422, permission}
	}
	if action.approval() && (role != "member" || status != "pending") {
		return "", &groupMembershipFailure{422, "只能处理待审批的普通成员"}
	}
	binds := []any{gb, targetBind}
	var details any
	switch action {
	case groupRole, groupMute, groupUnmute:
		if status != "active" && status != "muted" {
			return "", &groupMembershipFailure{422, permission}
		}
		if action == groupRole {
			newRank := groupMemberRank(change.role)
			if newRank < 1 || newRank >= rank {
				return "", &groupMembershipFailure{422, permission}
			}
			if change.role == role {
				return "", nil
			}
			query = groupMemberRoleSQL
			binds = append(binds, sql.Named("role", change.role))
			data, _ := json.Marshal(map[string]string{"old_role": role, "new_role": change.role})
			details = string(data)
		} else if action == groupMute {
			query = groupMuteSQL
			binds = append(binds, sql.Named("hours", change.hours), sql.Named("reason", change.reason))
			data, _ := json.Marshal(map[string]any{"duration_hours": change.hours, "reason": change.reason})
			details = string(data)
		} else {
			if status == "active" {
				return "", nil
			}
			query = groupUnmuteSQL
		}
	}
	if err := writeOneChatRow(ctx, tx, query, binds...); err != nil {
		return "", errSessionStore
	}
	expiry := ""
	if action == groupMute {
		if tx.QueryRowContext(ctx, groupMuteUntilSQL, gb, targetBind).Scan(&expiry) != nil || expiry == "" {
			return "", errSessionStore
		}
	}
	if writeOneChatRow(ctx, tx, groupAdmissionAuditSQL, gb, sql.Named("actor_id", viewer),
		sql.Named("target_user_id", userID), sql.Named("action", string(action)), sql.Named("details", details)) != nil ||
		tx.Commit() != nil {
		return "", errSessionStore
	}
	return expiry, nil
}

func groupAdmissionRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository) bool {
	path, matched := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	parts := strings.Split(path, "/")
	approve := r.Method == http.MethodPut && len(parts) == 4 && parts[3] == "approval-status"
	remove := r.Method == http.MethodDelete && len(parts) == 3
	role := r.Method == http.MethodPatch && len(parts) == 4 && (parts[3] == "role" || parts[3] == "roles")
	mute := r.Method == http.MethodPut && len(parts) == 4 && parts[3] == "mute-status"
	unmute := r.Method == http.MethodDelete && len(parts) == 4 && parts[3] == "mute-status"
	if !matched || (!approve && !remove && !role && !mute && !unmute) || parts[1] != "members" {
		return false
	}
	viewer, group, authenticated := interactionIdentity(w, r, codec, repo, parts[0])
	if !authenticated {
		return true
	}
	decoded, err := url.PathUnescape(parts[2])
	target, parseErr := strconv.ParseInt(decoded, 10, 64)
	if err != nil || parseErr != nil || !publicID.MatchString(decoded) || target > maxSocketID {
		respond(w, 400, 40001, "成员 ID 参数错误", nil)
		return true
	}
	change := groupMemberChange{action: groupRemove}
	if unmute {
		change.action = groupUnmute
	}
	if role || mute {
		raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		var fields map[string]json.RawMessage
		if err != nil || len(raw) > 1<<20 || json.Unmarshal(raw, &fields) != nil || fields == nil {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		if role {
			change.action = groupRole
			if json.Unmarshal(fields["role"], &change.role) != nil || groupMemberRank(change.role) < 1 || change.role == "owner" {
				respond(w, 400, 40001, "role 参数错误", nil)
				return true
			}
		} else {
			change.action = groupMute
			change.hours = 24
			if value, exists := fields["duration_hours"]; exists {
				var hours *float64
				if json.Unmarshal(value, &hours) != nil || hours == nil || *hours < 1 || *hours > 8760 || float64(int(*hours)) != *hours {
					respond(w, 400, 40001, "duration_hours 参数错误", nil)
					return true
				}
				change.hours = int(*hours)
			}
			if value, exists := fields["reason"]; exists {
				if json.Unmarshal(value, &change.reason) != nil || len(change.reason) > 200 {
					respond(w, 400, 40001, "reason 参数错误", nil)
					return true
				}
			}
		}
	}
	if approve {
		raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		var approved *bool
		var fields map[string]json.RawMessage
		if err != nil || len(raw) > 1<<20 || json.Unmarshal(raw, &fields) != nil ||
			json.Unmarshal(fields["approved"], &approved) != nil || approved == nil {
			respond(w, 400, 40001, "approved 参数错误", nil)
			return true
		}
		change.action = groupReject
		if *approved {
			change.action = groupApprove
		}
	}
	store, ok := repo.(groupAdmissionStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	expiry, err := store.ManageGroupMember(r.Context(), viewer, group, target, change)
	action := change.action
	var failure *groupMembershipFailure
	switch {
	case errors.As(err, &failure):
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	case action == groupRemove:
		respond(w, 200, 200, "member removed", nil)
	case action == groupRole:
		respond(w, 200, 200, "role updated", map[string]any{"user_id": target, "role": change.role})
	case action == groupMute:
		respond(w, 200, 200, "member muted", map[string]any{"user_id": target, "status": "muted", "mute_until": expiry})
	case action == groupUnmute:
		respond(w, 200, 200, "member unmuted", map[string]any{"user_id": target, "status": "active"})
	case action == groupApprove:
		respond(w, 200, 200, "member approved", map[string]any{"member_id": target, "status": "active"})
	default:
		respond(w, 200, 200, "member rejected", map[string]any{"member_id": target, "status": "rejected"})
	}
	return true
}
