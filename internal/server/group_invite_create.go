package server

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupInviteInput struct {
	Target         *int64
	MaxUses, Hours int64
	Message        *string
}

type groupInviteCreated struct {
	ID      int64   `json:"invite_id"`
	Code    *string `json:"invite_code"`
	URL     *string `json:"invite_url"`
	Expires string  `json:"expires_at"`
	notice  *notificationStored
}

type groupInviteCreateStore interface {
	CreateGroupInvite(context.Context, int64, int64, groupInviteInput) (groupInviteCreated, error)
	NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error)
}

const insertGroupInviteSQL = `INSERT INTO n_group_invites (invite_id,group_id,inviter_id,invitee_id,invite_code,max_uses,message,expires_at)
VALUES (:invite_id,:group_id,:inviter_id,:invitee_id,:invite_code,:max_uses,:message,SYSTIMESTAMP+NUMTODSINTERVAL(:expire_hours,'HOUR'))`
const groupInviteExpirySQL = `SELECT TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(expires_at,TO_CHAR(SYSTIMESTAMP,'TZH:TZM'))),'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS expires_at FROM n_group_invites WHERE invite_id=:invite_id`
const groupInviteTargetSQL = `SELECT user_id FROM n_users WHERE user_id=:target AND is_active=1 AND status='active'`
const groupInvitePreferenceSQL = `SELECT is_enabled FROM n_group_notification_preferences WHERE group_id=:group_id AND user_id=:user_id`
const groupInviteNamesSQL = `SELECT g.name,COALESCE(u.display_name,u.username) AS inviter_name FROM n_groups g JOIN n_users u ON u.user_id=:inviter_id WHERE g.group_id=:group_id`

func parseGroupInviteInput(raw []byte) (groupInviteInput, string) {
	out := groupInviteInput{MaxUses: 1, Hours: 168}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return out, "请求体必须是 JSON 对象"
	}
	bounded := func(raw json.RawMessage, max int64) (int64, bool) {
		var n *float64
		if json.Unmarshal(raw, &n) != nil || n == nil || *n < 1 || *n > float64(max) || float64(int64(*n)) != *n {
			return 0, false
		}
		return int64(*n), true
	}
	if v, found := fields["invitee_id"]; found && string(v) != "null" {
		id, ok := bounded(v, maxSocketID)
		if !ok {
			return out, "invitee_id 参数错误"
		}
		out.Target = &id
	}
	for _, param := range []struct {
		key string
		max int64
		dst *int64
	}{{"max_uses", 99999, &out.MaxUses}, {"expire_hours", 8760, &out.Hours}} {
		if v, found := fields[param.key]; found {
			n, ok := bounded(v, param.max)
			if !ok {
				return out, param.key + " 参数错误"
			}
			*param.dst = n
		}
	}
	if v, found := fields["message"]; found {
		if json.Unmarshal(v, &out.Message) != nil || out.Message != nil && len(*out.Message) > 200 {
			return out, "message 参数错误"
		}
	}
	if out.Target != nil {
		out.MaxUses = 1
	}
	return out, ""
}

func (s OracleSessions) CreateGroupInvite(ctx context.Context, viewer, group int64, in groupInviteInput) (groupInviteCreated, error) {
	var out groupInviteCreated
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return out, errSessionStore
	}
	defer tx.Rollback()
	gb := sql.Named("group_id", group)
	actor := sql.Named("inviter_id", viewer)
	var owner, approval, active, deleted int64
	var privacy string
	err = tx.QueryRowContext(ctx, membershipGroupSQL, gb).Scan(&owner, &privacy, &approval, &active, &deleted)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (active != 1 || deleted != 0) {
		return out, errGroupDetailMissing
	}
	if err != nil {
		return out, errSessionStore
	}
	var role, status string
	err = tx.QueryRowContext(ctx, membershipReadSQL, gb, sql.Named("user_id", viewer)).Scan(&role, &status)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (status != "active" || groupMemberRank(role) == 0) {
		return out, &groupMembershipFailure{422, "无权创建邀请"}
	}
	if err != nil {
		return out, errSessionStore
	}

	if in.Target == nil {
		var random [16]byte
		if _, err = rand.Read(random[:]); err != nil {
			return out, errSessionStore
		}
		code := strings.ToUpper(hex.EncodeToString(random[:]))
		link := "/groups/invite/" + code
		out.Code, out.URL = &code, &link
	} else {
		target := *in.Target
		if target == viewer {
			return out, &groupMembershipFailure{422, "不能邀请自己"}
		}
		var id int64
		err = tx.QueryRowContext(ctx, groupInviteTargetSQL, sql.Named("target", target)).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			return out, &groupMembershipFailure{404, "被邀请用户不存在"}
		}
		if err != nil {
			return out, errSessionStore
		}
		err = tx.QueryRowContext(ctx, membershipReadSQL, gb, sql.Named("user_id", target)).Scan(&role, &status)
		if err == nil {
			return out, &groupMembershipFailure{422, "被邀请用户已有群组成员记录"}
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return out, errSessionStore
		}
	}

	if tx.QueryRowContext(ctx, "SELECT seq_group_invite_id.NEXTVAL FROM dual").Scan(&out.ID) != nil || out.ID < 1 || out.ID > maxSocketID {
		return out, errSessionStore
	}
	invite := sql.Named("invite_id", out.ID)
	if writeOneChatRow(ctx, tx, insertGroupInviteSQL, invite, gb, actor, sql.Named("invitee_id", in.Target), sql.Named("invite_code", out.Code),
		sql.Named("max_uses", in.MaxUses), sql.Named("message", in.Message), sql.Named("expire_hours", in.Hours)) != nil ||
		tx.QueryRowContext(ctx, groupInviteExpirySQL, invite).Scan(&out.Expires) != nil || out.Expires == "" {
		return out, errSessionStore
	}
	if in.Target != nil {
		out.notice, err = storeGroupInviteNotice(ctx, tx, viewer, group, *in.Target, out.ID, in.Message)
		if err != nil {
			return out, err
		}
	}
	if tx.Commit() != nil {
		return out, errSessionStore
	}
	return out, nil
}

func storeGroupInviteNotice(ctx context.Context, tx *sql.Tx, viewer, group, target, invite int64, message *string) (*notificationStored, error) {
	var enabled int64
	gb := sql.Named("group_id", group)
	err := tx.QueryRowContext(ctx, groupInvitePreferenceSQL, gb, sql.Named("user_id", target)).Scan(&enabled)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, errSessionStore
	}
	if err == nil && enabled == 0 {
		return nil, nil
	}
	var name, inviter string
	if tx.QueryRowContext(ctx, groupInviteNamesSQL, gb, sql.Named("inviter_id", viewer)).Scan(&name, &inviter) != nil {
		return nil, errSessionStore
	}
	title := inviter + " 邀请你加入 " + name
	for len(title) > 200 {
		_, n := utf8.DecodeLastRuneInString(title)
		title = title[:len(title)-n]
	}
	content := "你收到了一条新的群组邀请。"
	if message != nil && *message != "" {
		content = *message
	}
	kind := "group_invite"
	return storeNotificationWith(ctx, tx, func(ctx context.Context, stmt string, binds ...any) error {
		return writeOneChatRow(ctx, tx, stmt, binds...)
	}, notificationInput{UserID: target, ActorID: &viewer, Type: kind, Title: title, Message: content, ResourceType: &kind,
		ResourceID: &invite, Priority: "normal", MetadataJSON: fmt.Sprintf(`{"group_id":%d,"invite_id":%d,"event":"group_invite_created"}`, group, invite)})
}

func groupInviteCreateRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	path, prefixed := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	id, match := strings.CutSuffix(path, "/invites")
	if r.Method != http.MethodPost || !prefixed || !match || id == "" || strings.Contains(id, "/") {
		return false
	}
	viewer, group, valid := interactionIdentity(w, r, codec, repo, id)
	if !valid {
		return true
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(raw) > 1<<20 {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	in, bad := parseGroupInviteInput(raw)
	if bad != "" {
		respond(w, 400, 40001, bad, nil)
		return true
	}
	store, ok := repo.(groupInviteCreateStore)
	if !ok {
		groupInviteReadError(w, errSessionStore)
		return true
	}
	out, err := store.CreateGroupInvite(r.Context(), viewer, group, in)
	if err != nil {
		groupInviteReadError(w, err)
		return true
	}
	if in.Target != nil && out.notice != nil && out.notice.PushEnabled && config.NotificationPublisher != nil {
		item, found, err := store.NotificationByID(r.Context(), *in.Target, out.notice.ID)
		if err == nil && found {
			err = hydrateNotification(r.Context(), repo, *in.Target, &item, config.Storage)
		}
		if err == nil && found {
			err = config.NotificationPublisher.Publish(r.Context(), *in.Target, "notification_created", map[string]any{"notification": item, "notification_type": "group_invite"})
		}
		if err != nil {
			log.Print("group invitation realtime delivery unavailable")
		}
	}
	respond(w, 200, 200, "invite created", out)
	return true
}
