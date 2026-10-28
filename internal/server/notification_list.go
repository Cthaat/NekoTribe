package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type NotificationItem struct {
	ID           int64       `json:"notification_id"`
	Type         string      `json:"type"`
	Title        string      `json:"title"`
	Message      string      `json:"message"`
	ResourceType *string     `json:"resource_type"`
	ResourceID   *int64      `json:"resource_id"`
	Priority     string      `json:"priority"`
	IsRead       int64       `json:"is_read"`
	ReadAt       *string     `json:"read_at"`
	DeletedAt    *string     `json:"deleted_at"`
	Actor        *PublicUser `json:"actor"`
	Metadata     any         `json:"metadata"`
	CreatedAt    string      `json:"created_at"`
	ActorID      *int64      `json:"-"`
}
type NotificationQuery struct {
	Page                    SessionPage
	Type                    string
	UnreadOnly, ShowDeleted bool
}
type notificationListStore interface {
	ListNotifications(context.Context, int64, NotificationQuery) ([]NotificationItem, int64, error)
}

func parseNotificationQuery(raw string) NotificationQuery {
	values := parseSessionQuery(raw)
	return NotificationQuery{Page: sessionPagination(values), Type: listQueryString(values, "type", "all"), UnreadOnly: listQueryString(values, "unread_only", "false") == "true", ShowDeleted: listQueryString(values, "show_deleted", "false") == "true"}
}

func notificationListSQL(user int64, q NotificationQuery) (string, string, []any) {
	where := "user_id=:user_id AND deleted_at IS NULL"
	if q.ShowDeleted {
		where = "user_id=:user_id AND deleted_at IS NOT NULL"
	}
	args := []any{sql.Named("user_id", user)}
	if q.Type != "" && q.Type != "all" {
		where += " AND type=:type"
		args = append(args, sql.Named("type", q.Type))
	}
	if q.UnreadOnly {
		where += " AND is_read=0"
	}
	count := "SELECT COUNT(*) FROM n_notifications WHERE " + where
	page := "SELECT notification_id,actor_id,type,title,message,resource_type,resource_id,priority,is_read,read_at,deleted_at,metadata_json,created_at FROM (SELECT notification_id,actor_id,type,title,message,resource_type,resource_id,priority,is_read,read_at,deleted_at,DBMS_LOB.SUBSTR(metadata_json,4000,1) AS metadata_json,created_at,ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn FROM n_notifications WHERE " + where + ") WHERE rn BETWEEN :start_row AND :end_row"
	return count, page, args
}

func (s OracleSessions) ListNotifications(ctx context.Context, user int64, q NotificationQuery) ([]NotificationItem, int64, error) {
	countSQL, pageSQL, args := notificationListSQL(user, q)
	var total int64
	if err := s.DB.QueryRowContext(ctx, countSQL, args...).Scan(&total); err != nil {
		return nil, 0, errSessionStore
	}
	pageArgs := append(append([]any{}, args...), sql.Named("start_row", q.Page.Start), sql.Named("end_row", q.Page.End))
	rows, err := s.DB.QueryContext(ctx, pageSQL, pageArgs...)
	if err != nil {
		return nil, 0, errSessionStore
	}
	items := make([]NotificationItem, 0)
	for rows.Next() {
		var item NotificationItem
		var actor, resourceID, isRead sql.NullInt64
		var kind, title, message, resourceType, priority, metadata sql.NullString
		var readAt, deletedAt, createdAt sql.NullTime
		if rows.Scan(&item.ID, &actor, &kind, &title, &message, &resourceType, &resourceID, &priority, &isRead, &readAt, &deletedAt, &metadata, &createdAt) != nil {
			rows.Close()
			return nil, 0, errSessionStore
		}
		item.ActorID = nullableInt(actor)
		item.Type = kind.String
		item.Title = title.String
		item.Message = message.String
		item.ResourceType = nullableString(resourceType)
		item.ResourceID = nullableInt(resourceID)
		item.Priority = priority.String
		item.IsRead = isRead.Int64
		item.ReadAt = profileDate(readAt)
		item.DeletedAt = profileDate(deletedAt)
		if date := profileDate(createdAt); date != nil {
			item.CreatedAt = *date
		}
		if metadata.Valid && metadata.String != "" {
			if json.Unmarshal([]byte(metadata.String), &item.Metadata) != nil {
				item.Metadata = metadata.String
			}
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		rows.Close()
		return nil, 0, errSessionStore
	}
	if rows.Close() != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}

func listNotifications(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
	w.Header().Set("Cache-Control", "private, no-store")
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	if n, e := repository.Touch(r.Context(), claims); e != nil || n != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	store, ok := repository.(notificationListStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	query := parseNotificationQuery(r.URL.RawQuery)
	items, total, err := store.ListNotifications(r.Context(), claims.UserID, query)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if items == nil {
		items = []NotificationItem{}
	}
	profiles, ok := repository.(publicProfileStore)
	for i := range items {
		if items[i].ActorID != nil && *items[i].ActorID != 0 {
			if !ok {
				respond(w, 500, 50001, "服务器内部错误", nil)
				return
			}
			actor, found, e := profiles.PublicProfile(r.Context(), claims.UserID, *items[i].ActorID)
			if e != nil {
				respond(w, 500, 50001, "服务器内部错误", nil)
				return
			}
			if found {
				actor.AvatarURL, e = normalizeAvatarURL(config.Storage, actor.AvatarURL)
				if e != nil {
					respond(w, 500, 50001, "服务器内部错误", nil)
					return
				}
				items[i].Actor = &actor
			}
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(struct {
		Code    int                `json:"code"`
		Message string             `json:"message"`
		Data    []NotificationItem `json:"data"`
		Meta    any                `json:"meta"`
	}{200, "success", items, map[string]any{"page": query.Page.Page, "page_size": query.Page.PageSize, "total": total, "has_next": query.Page.End < float64(total)}})
}
