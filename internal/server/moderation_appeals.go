package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type moderationAppealSpec struct {
	MaxResponseBytes    int
	Statuses, Decisions []string
	SQL                 map[string]string
}

var moderationAppealsContract = func() moderationAppealSpec {
	var spec moderationAppealSpec
	if json.Unmarshal(contracts.ModerationAppealsContract, &spec) != nil {
		panic("invalid moderation appeals contract")
	}
	return spec
}()

var errModerationAppealMissing = errors.New("moderation appeal missing")
var errModerationAppealHandled = errors.New("moderation appeal handled")

type moderationAppeal struct {
	ID            int64      `json:"appeal_id"`
	StatementID   int64      `json:"statement_id"`
	User          PublicUser `json:"user"`
	Message       string     `json:"appeal_message"`
	Status        string     `json:"appeal_status"`
	AdminResponse string     `json:"admin_response"`
	CreatedAt     string     `json:"created_at"`
	UpdatedAt     string     `json:"updated_at"`
}

type moderationAppealsStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ListModerationAppeals(context.Context, int64, string, SessionPage, StorageURLPolicy) ([]moderationAppeal, int64, error)
	DecideModerationAppeal(context.Context, int64, int64, string, string, StorageURLPolicy) (moderationAppeal, error)
}

func (s OracleSessions) ModerationAllowed(ctx context.Context, actor int64, policy moderationPolicy) (bool, error) {
	return checkModerationAccess(ctx, s.DB, actor, policy)
}

func scanModerationAppeal(row interface{ Scan(...any) error }, policy StorageURLPolicy, total *int64) (moderationAppeal, error) {
	var result moderationAppeal
	var id sql.NullInt64
	var message, status, response, created, updated sql.NullString
	user, err := scanPublicUser(row, &result.ID, &id, &message, &status, &response, &created, &updated, total)
	if err != nil {
		return result, err
	}
	if result.ID == 0 {
		return result, nil
	}
	if user.UserID <= 0 || !id.Valid {
		return result, errSessionStore
	}
	user.AvatarURL, err = normalizeAvatarURL(policy, user.AvatarURL)
	result.StatementID, result.User = id.Int64, user
	result.Message, result.Status, result.AdminResponse = message.String, status.String, response.String
	result.CreatedAt, result.UpdatedAt = created.String, updated.String
	return result, err
}

func (s OracleSessions) ListModerationAppeals(ctx context.Context, viewer int64, status string, page SessionPage, policy StorageURLPolicy) ([]moderationAppeal, int64, error) {
	rows, err := s.DB.QueryContext(ctx, moderationAppealsContract.SQL["list"], sql.Named("viewer_id", viewer), sql.Named("status", nullablePostString(status)),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	items := []moderationAppeal{}
	var total int64
	for rows.Next() {
		item, err := scanModerationAppeal(rows, policy, &total)
		if err != nil {
			return nil, 0, errSessionStore
		}
		if item.ID > 0 {
			items = append(items, item)
		}
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}

func (s OracleSessions) DecideModerationAppeal(ctx context.Context, viewer, appeal int64, status, reply string, policy StorageURLPolicy) (moderationAppeal, error) {
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) (moderationAppeal, error) {
		sqls := moderationAppealsContract.SQL
		id, actor := sql.Named("appeal_id", appeal), sql.Named("viewer_id", viewer)
		var owner int64
		var existing string
		var note sql.NullString
		err := tx.QueryRowContext(ctx, sqls["lock"], id).Scan(&owner, &existing, &note)
		if errors.Is(err, sql.ErrNoRows) {
			return moderationAppeal{}, errModerationAppealMissing
		}
		if err != nil {
			return moderationAppeal{}, errSessionStore
		}
		if existing == "pending" {
			response := sql.Named("response", nullablePostString(reply))
			update, err := tx.ExecContext(ctx, sqls["update"], id, sql.Named("status", status), response)
			if err != nil {
				return moderationAppeal{}, errSessionStore
			}
			if count, err := update.RowsAffected(); err != nil || count != 1 {
				return moderationAppeal{}, errSessionStore
			}
			audit, err := tx.ExecContext(ctx, sqls["audit"], sql.Named("target_id", owner), sql.Named("action", "appeal_"+status),
				actor, sql.Named("reason", "appeal:"+strconv.FormatInt(appeal, 10)), response)
			if err != nil {
				return moderationAppeal{}, errSessionStore
			}
			if count, err := audit.RowsAffected(); err != nil || count != 1 {
				return moderationAppeal{}, errSessionStore
			}
		} else if existing != status || note.String != reply {
			return moderationAppeal{}, errModerationAppealHandled
		}
		var total int64
		result, err := scanModerationAppeal(tx.QueryRowContext(ctx, sqls["read"], actor, id), policy, &total)
		if err != nil || result.ID != appeal {
			return moderationAppeal{}, errSessionStore
		}
		return result, nil
	})
}

func handleModerationAppeals(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	const base = "/api/v2/moderation/appeals"
	path := r.URL.EscapedPath()
	raw, under := strings.CutPrefix(path, base+"/")
	list := path == base && r.Method == http.MethodGet
	patch := under && raw != "" && !strings.Contains(raw, "/") && r.Method == http.MethodPatch
	if !list && !patch {
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	store, ok := repository.(moderationAppealsStore)
	if !ok {
		serverError()
		return true
	}
	allowed, err := store.ModerationAllowed(r.Context(), viewer, conversationPolicy(config.ModerationAllowAll, config.ModerationAdminAccounts))
	if err != nil {
		serverError()
		return true
	}
	if !allowed {
		respond(w, 403, 40301, "需要审核权限", nil)
		return true
	}
	if list {
		params := parseSessionQuery(r.URL.RawQuery)
		filter := listQueryString(params, "status", "all")
		if filter == "all" {
			filter = ""
		} else if !slices.Contains(moderationAppealsContract.Statuses, filter) {
			filter = "pending"
		}
		page := sessionPagination(params)
		items, total, err := store.ListModerationAppeals(r.Context(), viewer, filter, page, config.Storage)
		if err != nil {
			serverError()
			return true
		}
		if items == nil {
			items = []moderationAppeal{}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "moderation appeals listed", "data": items, "meta": map[string]any{
			"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total),
		}})
		return true
	}
	target, decodeErr := url.PathUnescape(raw)
	id, parseErr := strconv.ParseInt(target, 10, 64)
	if decodeErr != nil || parseErr != nil || !publicID.MatchString(target) || id > 9007199254740991 {
		respond(w, 400, 40001, "appeal_id 参数错误", nil)
		return true
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	status, _ := body["appeal_status"].(string)
	status = strings.TrimFunc(status, jsTrimSpace)
	if !slices.Contains(moderationAppealsContract.Decisions, status) {
		respond(w, 400, 40001, "appeal_status 参数错误", nil)
		return true
	}
	response := ""
	if value, provided := body["admin_response"]; provided {
		response, ok = value.(string)
		response = strings.TrimFunc(response, jsTrimSpace)
		if !ok || len(response) > moderationAppealsContract.MaxResponseBytes || strings.ContainsRune(response, 0) {
			respond(w, 400, 40001, "admin_response 参数错误", nil)
			return true
		}
	}
	result, err := store.DecideModerationAppeal(r.Context(), viewer, id, status, response, config.Storage)
	switch {
	case errors.Is(err, errModerationAppealMissing):
		respond(w, 404, 40401, "申诉不存在", nil)
	case errors.Is(err, errModerationAppealHandled):
		respond(w, 409, 40901, "申诉已处理", nil)
	case err != nil:
		serverError()
	default:
		respond(w, 200, 200, "appeal updated", result)
	}
	return true
}
