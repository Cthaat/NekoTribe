package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"time"
)

type otpVerificationStore interface {
	FindOTP(context.Context, string, string, string) (string, bool, error)
	MarkOTPVerified(context.Context, string) error
	OTPVerifiedAt(context.Context, string) (*time.Time, error)
}

const findOTPSQL = `SELECT verification_code_hash FROM n_auth_otp_events WHERE account = :account AND otp_type = :otp_type AND verification_id = :verification_id AND expires_at > CURRENT_TIMESTAMP ORDER BY created_at DESC FETCH FIRST 1 ROWS ONLY`
const markOTPSQL = `UPDATE n_auth_otp_events SET verified_at = CURRENT_TIMESTAMP WHERE verification_id = :verification_id`
const readOTPSQL = `SELECT verified_at FROM n_auth_otp_events WHERE verification_id = :verification_id`

func (s OracleSessions) FindOTP(ctx context.Context, account, kind, id string) (string, bool, error) {
	var hash sql.NullString
	err := s.DB.QueryRowContext(ctx, findOTPSQL, sql.Named("account", account), sql.Named("otp_type", kind), sql.Named("verification_id", id)).Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, errSessionStore
	}
	return hash.String, true, nil
}
func (s OracleSessions) MarkOTPVerified(ctx context.Context, id string) error {
	_, err := s.execute(ctx, markOTPSQL, sql.Named("verification_id", id))
	return err
}
func (s OracleSessions) OTPVerifiedAt(ctx context.Context, id string) (*time.Time, error) {
	var at sql.NullTime
	err := s.DB.QueryRowContext(ctx, readOTPSQL, sql.Named("verification_id", id)).Scan(&at)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, errSessionStore
	}
	if !at.Valid {
		return nil, nil
	}
	return &at.Time, nil
}
func verifyOTP(w http.ResponseWriter, r *http.Request, repository SessionRepository, config RefreshConfig) {
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	account := loginString(body["account"])
	if account == "" {
		respond(w, 400, 40001, "account 不能为空", nil)
		return
	}
	kind := loginString(body["type"])
	if kind == "" {
		respond(w, 400, 40001, "type 不能为空", nil)
		return
	}
	if kind != "register" && kind != "password_reset" && kind != "change_email" {
		respond(w, 400, 40001, "type 参数错误", nil)
		return
	}
	id := loginString(body["verification_id"])
	if id == "" {
		respond(w, 400, 40001, "verification_id 不能为空", nil)
		return
	}
	code := loginString(body["code"])
	if code == "" {
		respond(w, 400, 40001, "code 不能为空", nil)
		return
	}
	store, ok := repository.(otpVerificationStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	hash, found, err := store.FindOTP(r.Context(), account, kind, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 400, 40001, "验证码不存在或已过期", nil)
		return
	}
	if !matchesLoginPassword(hash, code) {
		respond(w, 401, 40101, "验证码错误", nil)
		return
	}
	if err = store.MarkOTPVerified(r.Context(), id); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	at, err := store.OTPVerifiedAt(r.Context(), id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if at == nil {
		now := config.clock()
		at = &now
	}
	respond(w, 200, 200, "success", map[string]interface{}{"account": account, "verified": true, "verified_at": at.UTC().Format("2006-01-02T15:04:05.000Z")})
}
