package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var (
	errFollowBlocked = errors.New("follow blocked")
	errFollowMissing = errors.New("follow target missing")
)

type followStore interface {
	ListUserFollows(context.Context, int64, int64, string, SessionPage) ([]visibilityItem, int64, error)
	WriteUserFollow(context.Context, int64, int64, bool) (int64, bool, error)
	PrepareFollowNotification(context.Context, int64, int64) (*notificationStored, error)
	NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error)
}

func (s OracleSessions) ListUserFollows(ctx context.Context, viewer, target int64, kind string, page SessionPage) ([]visibilityItem, int64, error) {
	return s.listRelationshipRows(ctx, viewer, &target, kind, page)
}

func (s OracleSessions) WriteUserFollow(ctx context.Context, actor, target int64, remove bool) (int64, bool, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, false, errSessionStore
	}
	defer tx.Rollback()
	found, err := lockVisibilityPair(ctx, tx, actor, target)
	if err != nil {
		return 0, false, err
	}
	if !found {
		if remove {
			return 0, false, nil
		}
		return 0, false, errFollowMissing
	}
	binds := []any{sql.Named("actor_id", actor), sql.Named("target_id", target)}
	if !remove {
		var id, blocked int64
		err = tx.QueryRowContext(ctx, visibilitySQL["activeTarget"], binds[1]).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			return 0, false, errFollowMissing
		}
		if err != nil || tx.QueryRowContext(ctx, visibilitySQL["blocked"], binds...).Scan(&blocked) != nil {
			return 0, false, errSessionStore
		}
		if blocked > 0 {
			return 0, false, errFollowBlocked
		}
	}
	statement := visibilitySQL["follow"]
	if remove {
		statement = visibilitySQL["unfollow"]
	}
	result, err := tx.ExecContext(ctx, statement, binds...)
	if err != nil {
		return 0, false, errSessionStore
	}
	changed, err := result.RowsAffected()
	if err != nil || changed > 1 {
		return 0, false, errSessionStore
	}
	var count sql.NullInt64
	err = tx.QueryRowContext(ctx, visibilitySQL["followCount"], binds[1]).Scan(&count)
	if err != nil && !errors.Is(err, sql.ErrNoRows) || tx.Commit() != nil {
		return 0, false, errSessionStore
	}
	return count.Int64, !remove && changed == 1, nil
}

func (s OracleSessions) PrepareFollowNotification(ctx context.Context, actor, target int64) (*notificationStored, error) {
	var name sql.NullString
	err := s.DB.QueryRowContext(ctx, visibilitySQL["followActor"], sql.Named("actor_id", actor)).Scan(&name)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, errSessionStore
	}
	if !name.Valid || name.String == "" {
		name.String = "有人"
	}
	resource := "user"
	return s.storeNotification(ctx, notificationInput{
		UserID: target, ActorID: &actor, Type: "follow", Title: name.String + " 关注了你",
		Message: "你收到了一个新的关注。", ResourceType: &resource, ResourceID: &actor,
		Priority: "normal", MetadataJSON: fmt.Sprintf(`{"target_user_id":%d,"event":"user_follow"}`, actor),
	})
}

func handleUserFollow(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/users/")
	raw, kind, scoped := strings.Cut(path, "/")
	if !ok || !scoped || raw == "" ||
		(kind != "followers" && kind != "following" && kind != "mutual-following") {
		return false
	}
	if r.Method != http.MethodGet && (kind != "followers" || (r.Method != http.MethodPost && r.Method != http.MethodDelete)) {
		return false
	}
	actor, target, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return true
	}
	store, ok := repository.(followStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if r.Method == http.MethodGet {
		page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
		rows, total, err := store.ListUserFollows(r.Context(), actor, target, kind, page)
		if err == nil {
			for i := range rows {
				rows[i].AvatarURL, err = normalizeAvatarURL(config.Storage, rows[i].AvatarURL)
				if err != nil {
					break
				}
			}
		}
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
		} else {
			writeRelationshipPage(w, rows, total, page)
		}
		return true
	}
	remove := r.Method == http.MethodDelete
	if !remove && actor == target {
		respond(w, 422, 42201, "不能关注自己", nil)
		return true
	}
	count, inserted, err := store.WriteUserFollow(r.Context(), actor, target, remove)
	switch {
	case errors.Is(err, errFollowBlocked):
		respond(w, 403, 40301, "无法关注该用户", nil)
	case errors.Is(err, errFollowMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		if inserted {
			deliverFollowNotification(r.Context(), repository, store, config, actor, target)
		}
		relation := "following"
		if remove {
			relation = "none"
		}
		respond(w, 200, 200, "success", map[string]any{"target_user_id": target, "relationship": relation, "followers_count": count})
	}
	return true
}

func deliverFollowNotification(ctx context.Context, repository SessionRepository, store followStore, config RefreshConfig, actor, target int64) {
	stored, err := store.PrepareFollowNotification(ctx, actor, target)
	if err != nil {
		log.Print("follow notification unavailable")
		return
	}
	if stored == nil || !stored.PushEnabled || config.NotificationPublisher == nil {
		return
	}
	item, found, err := store.NotificationByID(ctx, target, stored.ID)
	if err != nil || found && (hydrateNotification(ctx, repository, target, &item, config.Storage) != nil ||
		config.NotificationPublisher.Publish(ctx, target, "notification_created", map[string]any{"notification": item, "notification_type": "follow"}) != nil) {
		log.Print("follow notification unavailable")
	}
}
