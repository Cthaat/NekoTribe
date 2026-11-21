package server

import (
	"context"
	"database/sql"
	"net/http"

	"golang.org/x/crypto/bcrypt"
)

type passwordResetStore interface {
	FindOTP(context.Context, string, string, string) (string, bool, error)
	ResetPasswordAtomic(context.Context, string, string, string, string) (int, error)
}

const (
	resetCommitted = iota
	resetExpired
	resetUserMissing
)

const claimResetOTPSQL = `UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP, expires_at = CURRENT_TIMESTAMP, verification_code_hash = '!consumed!' WHERE account = :account AND otp_type = 'password_reset' AND verification_id = :verification_id AND verification_code_hash = :code_hash AND expires_at > CURRENT_TIMESTAMP`
const resetPasswordSQL = `UPDATE n_users SET password_hash = :password_hash WHERE email = :email`
const revokeResetSessionsSQL = `UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id IN (SELECT user_id FROM n_users WHERE email = :email) AND revoked_at IS NULL`
const invalidateResetChallengesSQL = `UPDATE n_auth_two_factor_challenges SET consumed_at = CURRENT_TIMESTAMP WHERE user_id IN (SELECT user_id FROM n_users WHERE email = :email) AND consumed_at IS NULL`
const revokeResetDevicesSQL = `UPDATE n_user_two_factor_trusted_devices SET revoked_at = CURRENT_TIMESTAMP WHERE user_id IN (SELECT user_id FROM n_users WHERE email = :email) AND revoked_at IS NULL`

func (s OracleSessions) ResetPasswordAtomic(ctx context.Context, email, id, codeHash, newHash string) (outcome int, err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return 0, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			outcome, err = 0, errSessionStore
		}
	}()
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return 0, errSessionStore
	}
	defer tx.Rollback()
	result, e := tx.ExecContext(ctx, claimResetOTPSQL, sql.Named("account", email), sql.Named("verification_id", id), sql.Named("code_hash", codeHash))
	if e != nil {
		return 0, errSessionStore
	}
	count, e := result.RowsAffected()
	if e != nil || count > 1 {
		return 0, errSessionStore
	}
	if count == 0 {
		return resetExpired, nil
	}
	result, e = tx.ExecContext(ctx, resetPasswordSQL, sql.Named("password_hash", newHash), sql.Named("email", email))
	if e != nil {
		return 0, errSessionStore
	}
	count, e = result.RowsAffected()
	if e != nil || count > 1 {
		return 0, errSessionStore
	}
	if count == 0 {
		return resetUserMissing, nil
	}
	for _, statement := range []string{revokeResetSessionsSQL, invalidateResetChallengesSQL, revokeResetDevicesSQL} {
		if _, e = tx.ExecContext(ctx, statement, sql.Named("email", email)); e != nil {
			return 0, errSessionStore
		}
	}
	if e = tx.Commit(); e != nil {
		return 0, errSessionStore
	}
	return resetCommitted, nil
}

func passwordReset(w http.ResponseWriter, r *http.Request, repository SessionRepository, limiter OTPAttemptLimiter) {
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	values := make(map[string]string, 4)
	for _, key := range []string{"email", "verification_id", "code", "new_password"} {
		values[key] = loginString(body[key])
		if values[key] == "" {
			respond(w, 400, 40001, key+" 不能为空", nil)
			return
		}
	}
	if !validNewPassword(values["new_password"]) {
		respond(w, 400, 40001, "密码至少需要6个字符", nil)
		return
	}
	store, ok := repository.(passwordResetStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	hash, found, err := store.FindOTP(r.Context(), values["email"], "password_reset", values["verification_id"])
	if err != nil {
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
	password := []byte(values["new_password"])
	if len(password) > 72 {
		password = password[:72]
	}
	newHash, err := bcrypt.GenerateFromPassword(password, 10)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	outcome, err := store.ResetPasswordAtomic(r.Context(), values["email"], values["verification_id"], hash, string(newHash))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if outcome == resetExpired {
		respond(w, 400, 40001, "验证码不存在或已过期", nil)
		return
	}
	if outcome == resetUserMissing {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	if outcome != resetCommitted {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "password reset success", nil)
}
