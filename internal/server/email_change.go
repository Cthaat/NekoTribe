package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	oracleErrors "github.com/oracle/go-oracledb/v26/oracle/errors"
)

type emailChangeData struct {
	Email      string `json:"email"`
	VerifiedAt string `json:"email_verified_at"`
}

const (
	emailCommitted = iota
	emailExpired
	emailUserMissing
	emailConflict
)

type emailChangeStore interface {
	EmailInUse(context.Context, int64, string) (bool, error)
	FindOTP(context.Context, string, string, string) (string, bool, error)
	ChangeEmailAtomic(context.Context, int64, string, string, string) (emailChangeData, int, error)
}

const emailInUseSQL = `SELECT COUNT(*) FROM n_users WHERE email = :email AND user_id != :user_id`
const claimEmailOTPSQL = `UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP, expires_at = CURRENT_TIMESTAMP, verification_code_hash = '!consumed!' WHERE account = :account AND otp_type = 'change_email' AND verification_id = :verification_id AND verification_code_hash = :code_hash AND expires_at > CURRENT_TIMESTAMP`
const updateEmailSQL = `UPDATE n_users SET email = :email, email_verified_at = CURRENT_TIMESTAMP WHERE user_id = :user_id`
const readEmailSQL = `SELECT email, TO_CHAR(FROM_TZ(email_verified_at, SESSIONTIMEZONE) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS email_verified_at FROM n_users WHERE user_id = :user_id`

func (s OracleSessions) EmailInUse(ctx context.Context, user int64, email string) (bool, error) {
	var count int64
	if err := s.DB.QueryRowContext(ctx, emailInUseSQL, sql.Named("email", email), sql.Named("user_id", user)).Scan(&count); err != nil || count < 0 {
		return false, errSessionStore
	}
	return count > 0, nil
}
func (s OracleSessions) ChangeEmailAtomic(ctx context.Context, user int64, email, id, hash string) (data emailChangeData, outcome int, err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return data, 0, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			data, outcome, err = emailChangeData{}, 0, errSessionStore
		}
	}()
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return data, 0, errSessionStore
	}
	committed := false
	defer func() {
		if !committed {
			if e := tx.Rollback(); e != nil && !errors.Is(e, sql.ErrTxDone) {
				data, outcome, err = emailChangeData{}, 0, errSessionStore
			}
		}
	}()
	result, e := tx.ExecContext(ctx, claimEmailOTPSQL, sql.Named("account", email), sql.Named("verification_id", id), sql.Named("code_hash", hash))
	if e != nil {
		return data, 0, errSessionStore
	}
	count, e := result.RowsAffected()
	if e != nil || count < 0 || count > 1 {
		return data, 0, errSessionStore
	}
	if count == 0 {
		return data, emailExpired, nil
	}
	result, e = tx.ExecContext(ctx, updateEmailSQL, sql.Named("email", email), sql.Named("user_id", user))
	if e != nil {
		var oracleError oracleErrors.SQLError
		if errors.As(e, &oracleError) && oracleError.ErrorCode() == "ORA-00001" {
			return data, emailConflict, nil
		}
		return data, 0, errSessionStore
	}
	count, e = result.RowsAffected()
	if e != nil || count < 0 || count > 1 {
		return data, 0, errSessionStore
	}
	if count == 0 {
		return data, emailUserMissing, nil
	}
	var readEmail sql.NullString
	var at sql.NullString
	if e = tx.QueryRowContext(ctx, readEmailSQL, sql.Named("user_id", user)).Scan(&readEmail, &at); e != nil || !readEmail.Valid || readEmail.String != email || !at.Valid || at.String == "" {
		return data, 0, errSessionStore
	}
	data = emailChangeData{Email: email, VerifiedAt: at.String}
	if e = tx.Commit(); e != nil {
		return emailChangeData{}, 0, errSessionStore
	}
	committed = true
	return data, emailCommitted, nil
}

func changeEmail(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, limiter OTPAttemptLimiter) {
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	claims, e := codec.Verify(token, auth.Access)
	if e != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	if count, e := repository.Touch(r.Context(), claims); e != nil || count != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	values := make(map[string]string, 3)
	for _, key := range []string{"new_email", "verification_id", "code"} {
		values[key] = loginString(body[key])
		if values[key] == "" {
			respond(w, 400, 40001, key+" 不能为空", nil)
			return
		}
	}
	store, ok := repository.(emailChangeStore)
	if !validNewEmail(values["new_email"]) {
		respond(w, 400, 40001, "邮箱格式错误", nil)
		return
	}
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	used, e := store.EmailInUse(r.Context(), claims.UserID, values["new_email"])
	if e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if used {
		respond(w, 409, 40901, "邮箱已被使用", nil)
		return
	}
	hash, found, e := store.FindOTP(r.Context(), values["new_email"], "change_email", values["verification_id"])
	if e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 400, 40001, "验证码不存在或已过期", nil)
		return
	}
	if !requireOTPAttempt(w, r, limiter, values["verification_id"]) {
		return
	}
	if !matchesLoginPassword(hash, values["code"]) {
		respond(w, 401, 40101, "验证码错误", nil)
		return
	}
	data, outcome, e := store.ChangeEmailAtomic(r.Context(), claims.UserID, values["new_email"], values["verification_id"], hash)
	if e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	switch outcome {
	case emailExpired:
		respond(w, 400, 40001, "验证码不存在或已过期", nil)
	case emailUserMissing:
		respond(w, 404, 40401, "用户不存在", nil)
	case emailConflict:
		respond(w, 409, 40901, "邮箱已被使用", nil)
	case emailCommitted:
		respond(w, 200, 200, "success", data)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
}
