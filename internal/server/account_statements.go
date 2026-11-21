package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type statementContractSpec struct {
	MaxAppealBytes int
	Actions        map[string]string
	SQL            map[string]string
}

var statementContract = func() statementContractSpec {
	var spec statementContractSpec
	if json.Unmarshal(contracts.AccountStatementsContract, &spec) != nil {
		panic("invalid account statement contract")
	}
	return spec
}()

var errStatementMissing = errors.New("account statement missing")
var errAppealPending = errors.New("appeal pending")

type accountStatement struct {
	ID         int64  `json:"statement_id"`
	Type       string `json:"type"`
	Title      string `json:"title"`
	Message    string `json:"message"`
	PolicyCode string `json:"policy_code"`
	Status     string `json:"status"`
	CreatedAt  string `json:"created_at"`
	UpdatedAt  string `json:"updated_at"`
}

type statementStatus struct {
	ID        int64  `json:"statement_id"`
	Status    string `json:"status"`
	UpdatedAt string `json:"updated_at"`
}

type statementAppeal struct {
	ID           int64  `json:"statement_id"`
	Status       string `json:"status"`
	AppealID     int64  `json:"appeal_id"`
	AppealStatus string `json:"appeal_status"`
}

type accountStatementStore interface {
	ListAccountStatements(context.Context, int64, string, string, SessionPage) ([]accountStatement, int64, error)
	SetAccountStatementStatus(context.Context, int64, int64, string) (statementStatus, error)
	SubmitAccountAppeal(context.Context, int64, int64, string) (statementAppeal, error)
}

func (s OracleSessions) ListAccountStatements(ctx context.Context, user int64, status, kind string, page SessionPage) ([]accountStatement, int64, error) {
	rows, err := s.DB.QueryContext(ctx, statementContract.SQL["list"], sql.Named("user_id", user),
		sql.Named("status", nullablePostString(status)), sql.Named("statement_type", nullablePostString(kind)),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	list := []accountStatement{}
	var total int64
	for rows.Next() {
		var item accountStatement
		var kind, title, message, policy, status, created, updated sql.NullString
		if err := rows.Scan(&item.ID, &kind, &title, &message, &policy, &status, &created, &updated, &total); err != nil {
			return nil, 0, errSessionStore
		}
		if item.ID > 0 {
			item.Type, item.Title, item.Message, item.PolicyCode = kind.String, title.String, message.String, policy.String
			item.Status, item.CreatedAt, item.UpdatedAt = status.String, created.String, updated.String
			list = append(list, item)
		}
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	return list, total, nil
}

func statementTransaction[T any](ctx context.Context, db *sql.DB, write func(*sql.Tx) (T, error)) (T, error) {
	var zero T
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return zero, errSessionStore
	}
	result, err := write(tx)
	if err != nil {
		if tx.Rollback() != nil {
			return zero, errSessionStore
		}
		return zero, err
	}
	if tx.Commit() != nil {
		return zero, errSessionStore
	}
	return result, nil
}

func writeStatementStatus(ctx context.Context, tx *sql.Tx, user, id int64, status string) error {
	result, err := tx.ExecContext(ctx, statementContract.SQL["update"], sql.Named("user_id", user), sql.Named("statement_id", id), sql.Named("status", status))
	if err != nil {
		return errSessionStore
	}
	count, err := result.RowsAffected()
	if err != nil || (count != 0 && count != 1) {
		return errSessionStore
	}
	if count == 0 {
		return errStatementMissing
	}
	return nil
}

func (s OracleSessions) SetAccountStatementStatus(ctx context.Context, user, id int64, status string) (statementStatus, error) {
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) (statementStatus, error) {
		if err := writeStatementStatus(ctx, tx, user, id, status); err != nil {
			return statementStatus{}, err
		}
		var scoped statementStatus
		err := tx.QueryRowContext(ctx, statementContract.SQL["readStatus"], sql.Named("user_id", user), sql.Named("statement_id", id)).
			Scan(&scoped.ID, &scoped.Status, &scoped.UpdatedAt)
		if err != nil || scoped.ID != id {
			return statementStatus{}, errSessionStore
		}
		return scoped, nil
	})
}

func (s OracleSessions) SubmitAccountAppeal(ctx context.Context, user, id int64, message string) (statementAppeal, error) {
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) (statementAppeal, error) {
		actor, target := sql.Named("user_id", user), sql.Named("statement_id", id)
		result := statementAppeal{ID: id, AppealStatus: "pending"}
		err := tx.QueryRowContext(ctx, statementContract.SQL["lock"], actor, target).Scan(&result.Status)
		if errors.Is(err, sql.ErrNoRows) {
			return statementAppeal{}, errStatementMissing
		}
		if err != nil {
			return statementAppeal{}, errSessionStore
		}
		var existing string
		err = tx.QueryRowContext(ctx, statementContract.SQL["pending"], actor, target).Scan(&result.AppealID, &existing)
		if err == nil {
			if existing != message {
				return statementAppeal{}, errAppealPending
			}
			return result, nil
		}
		if !errors.Is(err, sql.ErrNoRows) || tx.QueryRowContext(ctx, statementContract.SQL["next"]).Scan(&result.AppealID) != nil ||
			result.AppealID <= 0 || result.AppealID > 9007199254740991 {
			return statementAppeal{}, errSessionStore
		}
		applied, err := tx.ExecContext(ctx, statementContract.SQL["insert"], actor, target,
			sql.Named("appeal_id", result.AppealID), sql.Named("appeal_message", message))
		if err != nil {
			return statementAppeal{}, errSessionStore
		}
		if count, err := applied.RowsAffected(); err != nil || count != 1 {
			return statementAppeal{}, errSessionStore
		}
		result.Status = "appealed"
		if err := writeStatementStatus(ctx, tx, user, id, result.Status); err != nil {
			return statementAppeal{}, err
		}
		return result, nil
	})
}

func handleAccountStatements(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) bool {
	const base = "/api/v2/users/me/account-statements"
	path := r.URL.EscapedPath()
	if path == base && r.Method == http.MethodGet {
		user, ok := interactionActor(w, r, codec, repository)
		if ok {
			store, available := repository.(accountStatementStore)
			if !available {
				writeStatementResult(w, nil, errSessionStore)
				return true
			}
			query := parseSessionQuery(r.URL.RawQuery)
			filter := func(key string) string {
				value := listQueryString(query, key, "")
				if value == "all" {
					return ""
				}
				return value
			}
			page := sessionPagination(query)
			list, total, err := store.ListAccountStatements(r.Context(), user, filter("status"), filter("type"), page)
			if err != nil {
				writeStatementResult(w, nil, err)
			} else {
				writeRelationshipPage(w, list, total, page)
			}
		}
		return true
	}
	raw, scoped := strings.CutPrefix(path, base+"/")
	id, action, nested := strings.Cut(raw, "/")
	patch := scoped && !nested && r.Method == http.MethodPatch
	appeal := scoped && nested && action == "appeals" && r.Method == http.MethodPost
	if id == "" || !patch && !appeal {
		return false
	}
	user, target, ok := interactionIdentity(w, r, codec, repository, id)
	if !ok {
		return true
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	store, ok := repository.(accountStatementStore)
	if !ok {
		writeStatementResult(w, nil, errSessionStore)
		return true
	}
	if patch {
		key, _ := body["action"].(string)
		status := statementContract.Actions[strings.TrimFunc(key, jsTrimSpace)]
		if status == "" {
			respond(w, 400, 40001, "action 参数错误", nil)
			return true
		}
		data, err := store.SetAccountStatementStatus(r.Context(), user, target, status)
		writeStatementResult(w, data, err)
		return true
	}
	message, _ := body["appeal_message"].(string)
	message = strings.TrimFunc(message, jsTrimSpace)
	if message == "" {
		respond(w, 400, 40001, "appeal_message 不能为空", nil)
	} else if len(message) > statementContract.MaxAppealBytes || strings.ContainsRune(message, 0) {
		respond(w, 400, 40001, "appeal_message 参数错误", nil)
	} else {
		data, err := store.SubmitAccountAppeal(r.Context(), user, target, message)
		writeStatementResult(w, data, err)
	}
	return true
}

func writeStatementResult(w http.ResponseWriter, data any, err error) {
	switch {
	case errors.Is(err, errStatementMissing):
		respond(w, 404, 40401, "处置记录不存在", nil)
	case errors.Is(err, errAppealPending):
		respond(w, 409, 40901, "已有待处理申诉", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, "success", data)
	}
}
