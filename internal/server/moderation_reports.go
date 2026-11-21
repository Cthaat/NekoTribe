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

type reportSpec struct {
	Statuses, Reasons, TargetTypes []string
	SQL                            map[string]string
	Create                         struct {
		MaxTextBytes    int
		Priorities      []string
		EvidencePattern string
		Targets         map[string]string
	}
}

var moderationReportsContract = func() reportSpec {
	var spec reportSpec
	if err := json.Unmarshal(contracts.ModerationReportsContract, &spec); err != nil {
		panic("invalid moderation reports contract")
	}
	return spec
}()

type moderationReport struct {
	ID          int64       `json:"report_id"`
	TargetType  string      `json:"target_type"`
	TargetID    int64       `json:"target_id"`
	Reporter    *PublicUser `json:"reporter"`
	Reason      string      `json:"reason"`
	Description string      `json:"description"`
	EvidenceURL *string     `json:"evidence_url"`
	Status      string      `json:"status"`
	Priority    string      `json:"priority"`
	Handler     *PublicUser `json:"handled_by"`
	CreatedAt   string      `json:"created_at"`
	UpdatedAt   string      `json:"updated_at"`
	ResolvedAt  *string     `json:"resolved_at"`
}

type reportFilters struct{ Status, Reason, TargetType string }

type moderationReportsStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ListModerationReports(context.Context, int64, reportFilters, SessionPage, StorageURLPolicy) ([]moderationReport, int64, error)
	UpdateModerationReport(context.Context, int64, int64, string, StorageURLPolicy) (moderationReport, error)
}

type reportRow struct {
	moderationReport
	reporter, handler sql.NullInt64
}

func scanReport(row interface{ Scan(...any) error }, total *int64) (reportRow, error) {
	var result reportRow
	var id, target sql.NullInt64
	var kind, reason, description, evidence, status, priority, created, updated, resolved sql.NullString
	err := row.Scan(&id, &kind, &target, &result.reporter, &reason, &description, &evidence,
		&status, &priority, &result.handler, &created, &updated, &resolved, total)
	result.moderationReport = moderationReport{
		ID: id.Int64, TargetType: kind.String, TargetID: target.Int64, Reason: reason.String,
		Description: description.String, Status: status.String, Priority: priority.String,
		CreatedAt: created.String, UpdatedAt: updated.String,
	}
	if evidence.Valid {
		result.EvidenceURL = &evidence.String
	}
	if resolved.Valid {
		result.ResolvedAt = &resolved.String
	}
	return result, err
}

func (r reportRow) hydrate(ctx context.Context, q publicProfileQueryer, viewer int64, storage StorageURLPolicy) (moderationReport, error) {
	item := r.moderationReport
	load := func(id sql.NullInt64) (*PublicUser, error) {
		if !id.Valid {
			return nil, nil
		}
		user, found, err := readPublicProfile(ctx, q, viewer, id.Int64)
		if err != nil || !found {
			return nil, err
		}
		user.AvatarURL, err = normalizeAvatarURL(storage, user.AvatarURL)
		return &user, err
	}
	var err error
	item.Reporter, err = load(r.reporter)
	if err != nil {
		return moderationReport{}, err
	}
	item.Handler, err = load(r.handler)
	return item, err
}

func (s OracleSessions) ListModerationReports(ctx context.Context, viewer int64, f reportFilters, page SessionPage, storage StorageURLPolicy) ([]moderationReport, int64, error) {
	rows, err := s.DB.QueryContext(ctx, moderationReportsContract.SQL["list"], sql.Named("status", nullablePostString(f.Status)),
		sql.Named("reason", nullablePostString(f.Reason)), sql.Named("target_type", nullablePostString(f.TargetType)),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var total int64
	var records []reportRow
	for rows.Next() {
		item, err := scanReport(rows, &total)
		if err != nil {
			return nil, 0, err
		}
		if item.ID > 0 {
			records = append(records, item)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	items := make([]moderationReport, 0, len(records))
	for _, record := range records {
		item, err := record.hydrate(ctx, s.DB, viewer, storage)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, item)
	}
	return items, total, nil
}

func (s OracleSessions) UpdateModerationReport(ctx context.Context, viewer, id int64, status string, storage StorageURLPolicy) (moderationReport, error) {
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) (moderationReport, error) {
		queries := moderationReportsContract.SQL
		key := sql.Named("report_id", id)
		var current string
		var actor sql.NullInt64
		var resolved int
		if err := tx.QueryRowContext(ctx, queries["lock"], key).Scan(&current, &actor, &resolved); err != nil {
			return moderationReport{}, err
		}
		terminal := status == "resolved" || status == "dismissed"
		if current != status || actor.Int64 != viewer || (resolved == 1) != terminal {
			update, err := tx.ExecContext(ctx, queries["update"], key, sql.Named("status", status), sql.Named("handled_by", viewer))
			if err != nil {
				return moderationReport{}, err
			}
			if count, err := update.RowsAffected(); err != nil || count != 1 {
				return moderationReport{}, errSessionStore
			}
		}
		var total int64
		row, err := scanReport(tx.QueryRowContext(ctx, queries["read"], key), &total)
		if err != nil || row.ID != id {
			return moderationReport{}, errSessionStore
		}
		return row.hydrate(ctx, tx, viewer, storage)
	})
}

func reportFilter(value string, values []string, fallback string) string {
	if value == "all" {
		return ""
	}
	if slices.Contains(values, value) {
		return value
	}
	return fallback
}

func handleModerationReports(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	const base = "/api/v2/moderation/reports"
	path := r.URL.EscapedPath()
	if path == "/api/v2/reports" && r.Method == http.MethodPost {
		handleCreateReport(w, r, codec, repository, config.Storage)
		return true
	}
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
	store, ok := repository.(moderationReportsStore)
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
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
		spec := moderationReportsContract
		filters := reportFilters{
			Status:     reportFilter(listQueryString(params, "status", "all"), spec.Statuses, "pending"),
			Reason:     reportFilter(listQueryString(params, "reason", "all"), spec.Reasons, "other"),
			TargetType: reportFilter(listQueryString(params, "target_type", "all"), spec.TargetTypes, "post"),
		}
		page := sessionPagination(params)
		items, total, err := store.ListModerationReports(r.Context(), viewer, filters, page, config.Storage)
		if err != nil {
			serverError()
			return true
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "moderation reports listed", "data": items, "meta": map[string]any{
			"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total),
		}})
		return true
	}
	target, decodeErr := url.PathUnescape(raw)
	id, parseErr := strconv.ParseInt(target, 10, 64)
	if decodeErr != nil || parseErr != nil || !publicID.MatchString(target) || id > 9007199254740991 {
		respond(w, 400, 40001, "report_id 参数错误", nil)
		return true
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	status, _ := body["status"].(string)
	status = strings.TrimFunc(status, jsTrimSpace)
	if !slices.Contains(moderationReportsContract.Statuses, status) {
		respond(w, 400, 40001, "status 参数错误", nil)
		return true
	}
	item, err := store.UpdateModerationReport(r.Context(), viewer, id, status, config.Storage)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		respond(w, 404, 40401, "举报不存在", nil)
	case err != nil:
		serverError()
	default:
		respond(w, 200, 200, "report updated", item)
	}
	return true
}
