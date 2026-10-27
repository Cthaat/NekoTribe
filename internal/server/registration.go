package server

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"

	"golang.org/x/crypto/bcrypt"
)

type RegistrationRecord struct {
	UserID                                                                      int64
	Email, Username, PasswordHash, DisplayName, Bio, Location, Phone, BirthDate string
}

func (RegistrationRecord) String() string   { return "RegistrationRecord [redacted]" }
func (RegistrationRecord) GoString() string { return "RegistrationRecord [redacted]" }

type registrationStore interface {
	VerifiedRegistrationOTP(context.Context, string, string) (bool, error)
	RegistrationExists(context.Context, string, string) (bool, error)
	NextRegistrationID(context.Context) (int64, error)
	InsertRegistration(context.Context, RegistrationRecord) error
	SelfProfile(context.Context, int64) (SelfUser, bool, error)
}

const verifiedRegistrationOTPSQL = `SELECT verified_at FROM n_auth_otp_events WHERE account = :account AND otp_type = 'register' AND verification_id = :verification_id AND expires_at > CURRENT_TIMESTAMP AND verified_at IS NOT NULL`
const registrationExistsSQL = `SELECT COUNT(*) AS total FROM n_users WHERE email = :email OR username = :username`
const nextRegistrationIDSQL = `SELECT seq_user_id.NEXTVAL AS id FROM dual`
const insertRegistrationSQL = `INSERT INTO n_users (user_id,email,username,password_hash,display_name,bio,location,phone,birth_date,email_verified_at,status) VALUES (:user_id,:email,:username,:password_hash,:display_name,:bio,:location,:phone,CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END,CURRENT_TIMESTAMP,'active')`

func (s OracleSessions) VerifiedRegistrationOTP(ctx context.Context, email, id string) (bool, error) {
	var verified sql.NullTime
	err := s.DB.QueryRowContext(ctx, verifiedRegistrationOTPSQL, sql.Named("account", email), sql.Named("verification_id", id)).Scan(&verified)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, errSessionStore
	}
	return verified.Valid, nil
}
func (s OracleSessions) RegistrationExists(ctx context.Context, email, username string) (bool, error) {
	var total int64
	err := s.DB.QueryRowContext(ctx, registrationExistsSQL, sql.Named("email", email), sql.Named("username", username)).Scan(&total)
	if err != nil {
		return false, errSessionStore
	}
	return total > 0, nil
}
func (s OracleSessions) NextRegistrationID(ctx context.Context) (int64, error) {
	var id int64
	if err := s.DB.QueryRowContext(ctx, nextRegistrationIDSQL).Scan(&id); err != nil {
		return 0, errSessionStore
	}
	return id, nil
}
func nullableRegistration(v string) interface{} {
	if v == "" {
		return nil
	}
	return v
}
func (s OracleSessions) InsertRegistration(ctx context.Context, r RegistrationRecord) error {
	_, err := s.execute(ctx, insertRegistrationSQL, sql.Named("user_id", r.UserID), sql.Named("email", r.Email), sql.Named("username", r.Username), sql.Named("password_hash", r.PasswordHash), sql.Named("display_name", r.DisplayName), sql.Named("bio", nullableRegistration(r.Bio)), sql.Named("location", nullableRegistration(r.Location)), sql.Named("phone", nullableRegistration(r.Phone)), sql.Named("birth_date", nullableRegistration(r.BirthDate)))
	return err
}
func registrationString(v interface{}) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return jsNumberString(x)
	case bool:
		return fmt.Sprint(x)
	default:
		return ""
	}
}
func register(w http.ResponseWriter, r *http.Request, repository SessionRepository, config RefreshConfig) {
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	values := make(map[string]string, 6)
	for _, key := range []string{"email", "username", "password", "confirm_password", "display_name", "verification_id"} {
		values[key] = loginString(body[key])
		if values[key] == "" {
			respond(w, 400, 40001, key+" 不能为空", nil)
			return
		}
	}
	if agree, ok := body["agree_to_terms"].(bool); !ok || !agree {
		respond(w, 400, 40001, "必须同意服务条款", nil)
		return
	}
	if values["password"] != values["confirm_password"] {
		respond(w, 400, 40001, "两次输入的密码不一致", nil)
		return
	}
	store, ok := repository.(registrationStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	valid, err := store.VerifiedRegistrationOTP(r.Context(), values["email"], values["verification_id"])
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !valid {
		respond(w, 422, 42201, "请先完成验证码校验", nil)
		return
	}
	exists, err := store.RegistrationExists(r.Context(), values["email"], values["username"])
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if exists {
		respond(w, 409, 40901, "邮箱或用户名已被注册", nil)
		return
	}
	id, err := store.NextRegistrationID(r.Context())
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	password := []byte(values["password"])
	if len(password) > 72 {
		password = password[:72]
	}
	hash, err := bcrypt.GenerateFromPassword(password, 10)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	record := RegistrationRecord{UserID: id, Email: values["email"], Username: values["username"], PasswordHash: string(hash), DisplayName: values["display_name"], Bio: registrationString(body["bio"]), Location: registrationString(body["location"]), Phone: registrationString(body["phone"]), BirthDate: registrationString(body["birth_date"])}
	if err = store.InsertRegistration(r.Context(), record); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	profile, found, err := store.SelfProfile(r.Context(), id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	profile.AvatarURL, err = normalizeAvatarURL(config.Storage, profile.AvatarURL)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "registration success", map[string]interface{}{"user": profile})
}
