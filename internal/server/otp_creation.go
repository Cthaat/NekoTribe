package server

import (
	"context"
	"crypto/rand"
	"database/sql"
	"fmt"
	"golang.org/x/crypto/bcrypt"
	"math/big"
	"net/http"
	"time"
)

type OTPEvent struct {
	Sequence                         int64
	Account, Kind, Channel, Hash, ID string
	Expires                          time.Time
}

func (OTPEvent) String() string   { return "OTPEvent [redacted]" }
func (OTPEvent) GoString() string { return "OTPEvent [redacted]" }

type otpCreationStore interface {
	NextOTPID(context.Context) (int64, error)
	InsertOTP(context.Context, OTPEvent) error
}
type otpMailSender interface {
	SendOTP(context.Context, string, string) error
}

const nextOTPSQL = `SELECT seq_otp_event_id.NEXTVAL AS id FROM dual`
const insertOTPSQL = `INSERT INTO n_auth_otp_events (otp_event_id,account,otp_type,send_channel,verification_code_hash,verification_id,expires_at) VALUES (:otp_event_id,:account,:otp_type,:send_channel,:verification_code_hash,:verification_id,:expires_at)`

func (s OracleSessions) NextOTPID(ctx context.Context) (int64, error) {
	var id int64
	if err := s.DB.QueryRowContext(ctx, nextOTPSQL).Scan(&id); err != nil {
		return 0, errSessionStore
	}
	return id, nil
}
func (s OracleSessions) InsertOTP(ctx context.Context, e OTPEvent) error {
	_, err := s.execute(ctx, insertOTPSQL, sql.Named("otp_event_id", e.Sequence), sql.Named("account", e.Account), sql.Named("otp_type", e.Kind), sql.Named("send_channel", e.Channel), sql.Named("verification_code_hash", e.Hash), sql.Named("verification_id", e.ID), sql.Named("expires_at", e.Expires))
	return err
}
func createOTP(w http.ResponseWriter, r *http.Request, repository SessionRepository, config RefreshConfig) {
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
	channel := "email"
	switch value := body["channel"].(type) {
	case string:
		channel = value
	case bool:
		channel = fmt.Sprint(value)
	case float64:
		channel = fmt.Sprint(value)
	}
	if channel != "email" && channel != "sms" {
		respond(w, 400, 40001, "channel 参数错误", nil)
		return
	}
	if channel == "sms" {
		respond(w, 501, 50101, "短信验证码暂不可用", nil)
		return
	}
	store, ok := repository.(otpCreationStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	number, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	code := fmt.Sprintf("%06d", number.Int64())
	id, err := randomUUID()
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	id = "otp_" + id
	expiry := config.clock().UTC().Truncate(time.Millisecond).Add(300 * time.Second)
	seq, err := store.NextOTPID(r.Context())
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(code), 10)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if err = store.InsertOTP(r.Context(), OTPEvent{Sequence: seq, Account: account, Kind: kind, Channel: channel, Hash: string(hash), ID: id, Expires: expiry}); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if config.otpMailer == nil || config.otpMailer.SendOTP(r.Context(), account, code) != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "success", map[string]string{"account": account, "verification_id": id, "expires_at": expiry.Format("2006-01-02T15:04:05.000Z")})
}
