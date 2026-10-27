package server

import (
	"context"
	"database/sql"
	"net/http"

	"golang.org/x/crypto/bcrypt"
)

type passwordResetStore interface {
	otpVerificationStore
	ResetPassword(context.Context, string, string) (int64, error)
}

const resetPasswordSQL = `UPDATE n_users SET password_hash = :password_hash WHERE email = :email`

func (s OracleSessions) ResetPassword(ctx context.Context, email, hash string) (int64, error) {
	return s.execute(ctx, resetPasswordSQL, sql.Named("password_hash", hash), sql.Named("email", email))
}

func passwordReset(w http.ResponseWriter, r *http.Request, repository SessionRepository) {
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
	if !matchesLoginPassword(hash, values["code"]) {
		respond(w, 401, 40101, "验证码错误", nil)
		return
	}
	if err = store.MarkOTPVerified(r.Context(), values["verification_id"]); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if _, err = store.OTPVerifiedAt(r.Context(), values["verification_id"]); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
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
	count, err := store.ResetPassword(r.Context(), values["email"], string(newHash))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if count == 0 {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	respond(w, 200, 200, "password reset success", nil)
}
