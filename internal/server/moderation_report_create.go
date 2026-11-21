package server

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var (
	errOpenReport      = errors.New("open report already exists")
	reportEvidenceLink = regexp.MustCompile(moderationReportsContract.Create.EvidencePattern)
)

type reportInput struct {
	TargetID                                               int64
	TargetType, Reason, Priority, Description, EvidenceURL string
}

type reportCreator interface {
	CreateReport(context.Context, int64, reportInput, StorageURLPolicy) (moderationReport, error)
}

func parseReportInput(body map[string]any) (reportInput, string) {
	spec := moderationReportsContract
	field := func(key string) string {
		value, _ := body[key].(string)
		return strings.TrimFunc(value, jsTrimSpace)
	}
	var input reportInput
	input.TargetType = field("target_type")
	if !slices.Contains(spec.TargetTypes, input.TargetType) {
		return input, "target_type"
	}
	switch value := body["target_id"].(type) {
	case float64:
		if value >= 1 && value <= 9007199254740991 && math.Trunc(value) == value {
			input.TargetID = int64(value)
		}
	case string:
		if publicID.MatchString(value) {
			input.TargetID, _ = strconv.ParseInt(value, 10, 64)
		}
	}
	if input.TargetID <= 0 || input.TargetID > 9007199254740991 {
		return input, "target_id"
	}
	input.Reason = field("reason")
	if !slices.Contains(spec.Reasons, input.Reason) {
		return input, "reason"
	}
	input.Priority = "normal"
	if _, provided := body["priority"]; provided {
		input.Priority = field("priority")
		if !slices.Contains(spec.Create.Priorities, input.Priority) {
			return input, "priority"
		}
	}
	for _, text := range []struct {
		key  string
		dest *string
	}{
		{"description", &input.Description}, {"evidence_url", &input.EvidenceURL},
	} {
		if body[text.key] == nil {
			continue
		}
		value, ok := body[text.key].(string)
		value = strings.TrimFunc(value, jsTrimSpace)
		if !ok || len(value) > spec.Create.MaxTextBytes || strings.ContainsRune(value, 0) {
			return input, text.key
		}
		*text.dest = value
	}
	if input.EvidenceURL != "" && !reportEvidenceLink.MatchString(input.EvidenceURL) {
		return input, "evidence_url"
	}
	return input, ""
}

func (s OracleSessions) CreateReport(ctx context.Context, viewer int64, input reportInput, storage StorageURLPolicy) (moderationReport, error) {
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) (moderationReport, error) {
		spec := moderationReportsContract
		kind, target, actor := sql.Named("target_type", input.TargetType), sql.Named("target_id", input.TargetID), sql.Named("viewer_id", viewer)
		var visible int64
		if err := tx.QueryRowContext(ctx, spec.Create.Targets[input.TargetType], target, actor).Scan(&visible); err != nil {
			return moderationReport{}, err
		}
		var id int64
		var reason, description, evidence, priority sql.NullString
		err := tx.QueryRowContext(ctx, spec.SQL["findOpen"], kind, target, actor).Scan(&id, &reason, &description, &evidence, &priority)
		switch {
		case err == nil:
			if reason.String != input.Reason || description.String != input.Description || evidence.String != input.EvidenceURL || priority.String != input.Priority {
				return moderationReport{}, errOpenReport
			}
		case errors.Is(err, sql.ErrNoRows):
			if err := tx.QueryRowContext(ctx, spec.SQL["next"]).Scan(&id); err != nil || id <= 0 {
				return moderationReport{}, errSessionStore
			}
			insert, err := tx.ExecContext(ctx, spec.SQL["insert"], sql.Named("report_id", id), kind, target, actor,
				sql.Named("reason", input.Reason), sql.Named("description", nullablePostString(input.Description)),
				sql.Named("evidence_url", nullablePostString(input.EvidenceURL)), sql.Named("priority", input.Priority))
			if err != nil {
				return moderationReport{}, errSessionStore
			}
			if n, err := insert.RowsAffected(); err != nil || n != 1 {
				return moderationReport{}, errSessionStore
			}
			stats, err := tx.ExecContext(ctx, spec.SQL["mergeCase"], kind, target)
			if err != nil {
				return moderationReport{}, errSessionStore
			}
			if n, err := stats.RowsAffected(); err != nil || n != 1 {
				return moderationReport{}, errSessionStore
			}
		default:
			return moderationReport{}, errSessionStore
		}
		var total int64
		row, err := scanReport(tx.QueryRowContext(ctx, spec.SQL["read"], sql.Named("report_id", id)), &total)
		if err != nil || row.ID != id {
			return moderationReport{}, errSessionStore
		}
		return row.hydrate(ctx, tx, viewer, storage)
	})
}

func handleCreateReport(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) {
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	input, invalid := parseReportInput(body)
	if invalid != "" {
		respond(w, 400, 40001, invalid+" 参数错误", nil)
		return
	}
	if input.TargetType == "user" && input.TargetID == viewer {
		respond(w, 403, 40301, "不能举报自己", nil)
		return
	}
	store, ok := repo.(reportCreator)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	result, err := store.CreateReport(r.Context(), viewer, input, storage)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		respond(w, 404, 40401, "举报目标不存在", nil)
	case errors.Is(err, errOpenReport):
		respond(w, 409, 40901, "已有待处理举报", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, "report created", result)
	}
}
