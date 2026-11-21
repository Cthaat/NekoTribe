package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var moderationDashboardContract = func() struct {
	Settings  map[string]string
	MaxNumber int64
	SQL       map[string]string
} {
	var spec struct {
		Settings  map[string]string
		MaxNumber int64
		SQL       map[string]string
	}
	if err := json.Unmarshal(contracts.ModerationDashboardContract, &spec); err != nil {
		panic("invalid moderation dashboard contract")
	}
	return spec
}()

type dashboardStats struct {
	Pending           int64 `json:"pending"`
	Approved          int64 `json:"approved"`
	Rejected          int64 `json:"rejected"`
	Flagged           int64 `json:"flagged"`
	TodayProcessed    int64 `json:"today_processed"`
	AverageMinutes    int64 `json:"avg_process_minutes"`
	OpenReports       int64 `json:"open_reports"`
	AppealSuccessRate int64 `json:"appeal_success_rate"`
}

type dashboardSetting struct {
	Key         string `json:"key"`
	Value       string `json:"value"`
	Type        string `json:"value_type"`
	Label       string `json:"label"`
	Description string `json:"description"`
	Updated     string `json:"updated_at"`
}

type dashboardChange struct{ key, value, kind string }

type moderationDashboardStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ModerationStats(context.Context) (dashboardStats, error)
	ModerationSettings(context.Context) ([]dashboardSetting, error)
	UpdateModerationSettings(context.Context, int64, []dashboardChange) ([]dashboardSetting, error)
}

func dashboardValue(raw any, kind string) (string, bool) {
	if text, ok := raw.(string); ok {
		raw = strings.TrimFunc(text, jsTrimSpace)
	}
	if kind == "boolean" {
		switch raw {
		case true, "true", "1":
			return "true", true
		case false, "false", "0":
			return "false", true
		default:
			return "", false
		}
	}
	maxNumber := moderationDashboardContract.MaxNumber
	switch value := raw.(type) {
	case string:
		if value == "" || strings.IndexFunc(value, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
			return "", false
		}
		digits := strings.TrimLeft(value, "0")
		if digits == "" {
			return "0", true
		}
		number, err := strconv.ParseInt(digits, 10, 64)
		if err == nil && number <= maxNumber {
			return strconv.FormatInt(number, 10), true
		}
	case float64:
		if value >= 0 && value <= float64(maxNumber) && math.Trunc(value) == value {
			return strconv.FormatInt(int64(value), 10), true
		}
	}
	return "", false
}

func dashboardChanges(raw any) ([]dashboardChange, bool) {
	items, ok := raw.([]any)
	registry := moderationDashboardContract.Settings
	if !ok || len(items) > len(registry) {
		return nil, false
	}
	result := make([]dashboardChange, 0, len(items))
	seen := map[string]bool{}
	for _, entry := range items {
		item, ok := entry.(map[string]any)
		if !ok {
			return nil, false
		}
		key, _ := item["key"].(string)
		kind, known := registry[key]
		if !known || seen[key] {
			return nil, false
		}
		value, ok := dashboardValue(item["value"], kind)
		if !ok {
			return nil, false
		}
		seen[key] = true
		result = append(result, dashboardChange{key, value, kind})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].key < result[j].key })
	return result, true
}

func (s OracleSessions) ModerationStats(ctx context.Context) (dashboardStats, error) {
	var stats dashboardStats
	err := s.DB.QueryRowContext(ctx, moderationDashboardContract.SQL["stats"]).Scan(
		&stats.Pending, &stats.Approved, &stats.Rejected, &stats.Flagged, &stats.TodayProcessed,
		&stats.AverageMinutes, &stats.OpenReports, &stats.AppealSuccessRate,
	)
	return stats, err
}

func listDashboardSettings(ctx context.Context, q interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}) ([]dashboardSetting, error) {
	rows, err := q.QueryContext(ctx, moderationDashboardContract.SQL["list"])
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []dashboardSetting{}
	for rows.Next() {
		var key, value, kind, label, description, updated sql.NullString
		if err := rows.Scan(&key, &value, &kind, &label, &description, &updated); err != nil {
			return nil, err
		}
		if kind.String != "number" && kind.String != "boolean" {
			kind.String = "string"
		}
		items = append(items, dashboardSetting{key.String, value.String, kind.String, label.String, description.String, updated.String})
	}
	return items, rows.Err()
}

func (s OracleSessions) ModerationSettings(ctx context.Context) ([]dashboardSetting, error) {
	return listDashboardSettings(ctx, s.DB)
}

func (s OracleSessions) UpdateModerationSettings(ctx context.Context, actor int64, batch []dashboardChange) ([]dashboardSetting, error) {
	if len(batch) == 0 {
		return s.ModerationSettings(ctx)
	}
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) ([]dashboardSetting, error) {
		for _, entry := range batch {
			result, err := tx.ExecContext(ctx, moderationDashboardContract.SQL["update"],
				sql.Named("setting_value", entry.value), sql.Named("setting_key", entry.key),
				sql.Named("updated_by", actor), sql.Named("value_type", entry.kind))
			if err != nil {
				return nil, err
			}
			if n, err := result.RowsAffected(); err != nil || n != 1 {
				return nil, errSessionStore
			}
		}
		return listDashboardSettings(ctx, tx)
	})
}

func handleModerationDashboard(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	path := r.URL.EscapedPath()
	stats := path == "/api/v2/moderation/stats" && r.Method == http.MethodGet
	settings := path == "/api/v2/moderation/settings" && (r.Method == http.MethodGet || r.Method == http.MethodPatch)
	if !stats && !settings {
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	store, ok := repo.(moderationDashboardStore)
	if !ok {
		serverError()
		return true
	}
	ctx := r.Context()
	allowed, err := store.ModerationAllowed(ctx, viewer, conversationPolicy(config.ModerationAllowAll, config.ModerationAdminAccounts))
	if err != nil {
		serverError()
		return true
	}
	if !allowed {
		respond(w, 403, 40301, "需要审核权限", nil)
		return true
	}
	if stats {
		data, err := store.ModerationStats(ctx)
		if err != nil {
			serverError()
			return true
		}
		respond(w, 200, 200, "success", data)
		return true
	}
	var data []dashboardSetting
	if r.Method == http.MethodPatch {
		body, ok := readLoginBody(r)
		if !ok {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		batch, ok := dashboardChanges(body["settings"])
		if !ok {
			respond(w, 400, 40001, "settings 参数错误", nil)
			return true
		}
		data, err = store.UpdateModerationSettings(ctx, viewer, batch)
	} else {
		data, err = store.ModerationSettings(ctx)
	}
	if err != nil {
		serverError()
		return true
	}
	respond(w, 200, 200, "success", data)
	return true
}
