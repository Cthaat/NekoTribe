package server

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/crypto/bcrypt"
	"log"
	"net/http"
	"strings"
)

type accountDeletionStore interface {
	SelfProfile(context.Context, int64) (SelfUser, bool, error)
	AccountCredential(context.Context, int64) (LoginAccount, bool, error)
	DeleteAccountAtomic(context.Context, int64, string, string) (bool, error)
	UserPresence(context.Context, int64) (userPresence, error)
}

const deletePostsSQL = `UPDATE n_posts SET is_deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE author_id = :user_id AND is_deleted = 0`
const deleteCommentsSQL = `UPDATE n_comments SET is_deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND is_deleted = 0`
const deleteSessionsSQL = `UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND revoked_at IS NULL`
const deleteUserSQL = `UPDATE n_users SET email = :email, username = :username, password_hash = :password_hash, display_name = '已注销用户', bio = NULL, location = NULL, website = NULL, phone = NULL, avatar_url = NULL, avatar_media_id = NULL, is_active = 0, status = 'disabled', updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND password_hash = :old_hash AND is_active = 1 AND status = 'active'`

func fmtDeleted(user int64) string { return fmt.Sprintf("deleted_%d", user) }

func (s OracleSessions) AccountCredential(ctx context.Context, user int64) (LoginAccount, bool, error) {
	var a LoginAccount
	var active int64
	err := s.DB.QueryRowContext(ctx, `SELECT password_hash, status, is_active FROM n_users WHERE user_id = :user_id`, sql.Named("user_id", user)).Scan(&a.PasswordHash, &a.Status, &active)
	if errors.Is(err, sql.ErrNoRows) {
		return a, false, nil
	}
	if err != nil {
		return a, false, errSessionStore
	}
	a.UserID = user
	a.Active = active == 1
	return a, true, nil
}
func (s OracleSessions) DeleteAccountAtomic(ctx context.Context, user int64, oldHash, newHash string) (changed bool, err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return false, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			changed, err = false, errSessionStore
		}
	}()
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return false, errSessionStore
	}
	committed := false
	defer func() {
		if !committed {
			if e := tx.Rollback(); e != nil && !errors.Is(e, sql.ErrTxDone) {
				changed, err = false, errSessionStore
			}
		}
	}()
	for _, query := range []string{deletePostsSQL, deleteCommentsSQL, deleteSessionsSQL} {
		result, e := tx.ExecContext(ctx, query, sql.Named("user_id", user))
		if e != nil {
			return false, errSessionStore
		}
		n, e := result.RowsAffected()
		if e != nil || n < 0 {
			return false, errSessionStore
		}
	}
	result, e := tx.ExecContext(ctx, deleteUserSQL, sql.Named("user_id", user), sql.Named("email", fmtDeleted(user)+"@deleted.local"), sql.Named("username", fmtDeleted(user)), sql.Named("password_hash", newHash), sql.Named("old_hash", oldHash))
	if e != nil {
		return false, errSessionStore
	}
	n, e := result.RowsAffected()
	if e != nil || n < 0 || n > 1 {
		return false, errSessionStore
	}
	if n == 0 {
		return false, nil
	}
	if tx.Commit() != nil {
		return false, errSessionStore
	}
	committed = true
	return true, nil
}
func deleteAccount(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
	w.Header().Set("Cache-Control", "private, no-store")
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	store, ok := repository.(accountDeletionStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	profile, found, e := store.SelfProfile(r.Context(), user)
	if e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	password, confirmation := loginString(body["password"]), loginString(body["confirmation"])
	if password == "" {
		respond(w, 400, 40001, "password 不能为空", nil)
		return
	}
	if confirmation == "" {
		respond(w, 400, 40001, "confirmation 不能为空", nil)
		return
	}
	if confirmation != profile.Username && strings.ToUpper(confirmation) != "DELETE" {
		respond(w, 400, 40001, "确认内容不匹配", nil)
		return
	}
	account, found, e := store.AccountCredential(r.Context(), user)
	if e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	if !account.Active || account.Status != "active" {
		respond(w, 403, 40301, "账号不可用", nil)
		return
	}
	if !matchesLoginPassword(account.PasswordHash, password) {
		respond(w, 401, 40101, "密码错误", nil)
		return
	}
	var secret [32]byte
	if _, e = rand.Read(secret[:]); e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	hash, e := bcrypt.GenerateFromPassword([]byte(hex.EncodeToString(secret[:])), 10)
	if e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	changed, e := store.DeleteAccountAtomic(r.Context(), user, account.PasswordHash, string(hash))
	if e != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !changed {
		respond(w, 409, 40901, "账号已变更，请重新验证", nil)
		return
	}
	if presence, e := store.UserPresence(r.Context(), user); e == nil {
		if config.PresencePublisher != nil && config.PresencePublisher.PublishPresence(r.Context(), presence) != nil {
			log.Print("presence delivery unavailable")
		}
	} else {
		log.Print("presence delivery unavailable")
	}
	for _, name := range []string{"access_token", "refresh_token"} {
		http.SetCookie(w, &http.Cookie{Name: name, Value: "", Path: "/", MaxAge: -1})
	}
	respond(w, 200, 200, "success", map[string]interface{}{"deleted": true, "user_id": user})
}
