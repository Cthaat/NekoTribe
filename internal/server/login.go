package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/crypto/bcrypt"
)

// LoginAccount deliberately has no String method exposing its password hash.
type LoginAccount struct {
	UserID                         int64
	Username, PasswordHash, Status string
	Active                         bool
}

func (LoginAccount) String() string   { return "LoginAccount [redacted]" }
func (LoginAccount) GoString() string { return "LoginAccount [redacted]" }

type LoginSession struct {
	UserID                                                                                 int64
	SessionID, AccessJTI, RefreshHash, DeviceInfo, DeviceFingerprint, IPAddress, UserAgent string
	AccessExpiresAt, RefreshExpiresAt                                                      time.Time
}

type SelfUser struct {
	UserID          int64            `json:"user_id"`
	Username        string           `json:"username"`
	DisplayName     string           `json:"display_name"`
	AvatarURL       string           `json:"avatar_url"`
	Bio             string           `json:"bio"`
	Location        string           `json:"location"`
	Website         string           `json:"website"`
	IsVerified      int64            `json:"is_verified"`
	FollowersCount  int64            `json:"followers_count"`
	FollowingCount  int64            `json:"following_count"`
	PostsCount      int64            `json:"posts_count"`
	LikesCount      int64            `json:"likes_count"`
	Relationship    SelfRelationship `json:"relationship"`
	OnlineStatus    string           `json:"online_status"`
	LastSeenAt      *string          `json:"last_seen_at"`
	Email           string           `json:"email"`
	Phone           string           `json:"phone"`
	BirthDate       *string          `json:"birth_date"`
	EmailVerifiedAt *string          `json:"email_verified_at"`
	IsActive        int64            `json:"is_active"`
	Status          string           `json:"status"`
	CreatedAt       string           `json:"created_at"`
	UpdatedAt       string           `json:"updated_at"`
}
type SelfRelationship struct {
	IsSelf      bool   `json:"is_self"`
	IsFollowing bool   `json:"is_following"`
	IsBlocked   bool   `json:"is_blocked"`
	IsBlocking  bool   `json:"is_blocking"`
	Relation    string `json:"relation"`
}

type LoginRepository interface {
	LookupLogin(context.Context, string) (LoginAccount, bool, error)
	CheckTwoFactorSchema(context.Context) error
	TwoFactorEnabled(context.Context, int64) (bool, error)
	InsertLoginSession(context.Context, LoginSession) error
	UpdateLastLogin(context.Context, int64) error
	SelfProfile(context.Context, int64) (SelfUser, bool, error)
	KnownLoginDevice(context.Context, int64, string) (bool, error)
	RecordLoginAlert(context.Context, LoginSession) error
}

func readLoginBody(r *http.Request) (map[string]interface{}, bool) {
	b, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(b) > 1<<20 {
		return nil, false
	}
	var body map[string]interface{}
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/x-www-form-urlencoded") {
		body = parseLoginForm(b)
		if body == nil {
			return nil, false
		}
	} else if strings.HasPrefix(r.Header.Get("Content-Type"), "text/") || json.Unmarshal(b, &body) != nil || body == nil {
		return nil, false
	}
	return body, true
}

func login(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	account := loginString(body["account"])
	password := loginString(body["password"])
	if account == "" {
		respond(w, 400, 40001, "account 不能为空", nil)
		return
	}
	if password == "" {
		respond(w, 400, 40001, "password 不能为空", nil)
		return
	}
	store, ok := repository.(LoginRepository)
	if !ok {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	user, found, err := store.LookupLogin(r.Context(), account)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 401, 40101, "账号或密码错误", nil)
		return
	}
	if !user.Active || user.Status != "active" {
		respond(w, 403, 40301, "账号不可用", nil)
		return
	}
	if !matchesLoginPassword(user.PasswordHash, password) {
		respond(w, 401, 40101, "账号或密码错误", nil)
		return
	}
	if err := store.CheckTwoFactorSchema(r.Context()); err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	enabled, err := store.TwoFactorEnabled(r.Context(), user.UserID)
	if err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	if enabled {
		remember, _ := body["remember_me"].(bool)
		beginTwoFactor(w, r, codec, store, user, account, remember, config)
		return
	}
	issueLogin(w, r, codec, store, user, config)
}

func matchesLoginPassword(hash, password string) bool {
	passwordBytes := []byte(password)
	if len(passwordBytes) > 72 {
		passwordBytes = passwordBytes[:72]
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), passwordBytes) == nil
}

func parseLoginForm(raw []byte) map[string]interface{} {
	values, err := url.ParseQuery(string(raw))
	if err != nil {
		return nil
	}
	result := map[string]interface{}{}
	for k, v := range values {
		if len(v) == 1 {
			result[k] = v[0]
		} else {
			result[k] = v
		}
	}
	return result
}
func loginString(value interface{}) string {
	switch v := value.(type) {
	case string:
		return strings.TrimFunc(v, jsTrimSpace)
	case float64:
		return strings.TrimSpace(fmt.Sprint(v))
	case bool:
		return fmt.Sprint(v)
	default:
		return ""
	}
}
func jsTrimSpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', '\u00a0', '\u1680', '\u2028', '\u2029', '\u202f', '\u205f', '\u3000', '\ufeff':
		return true
	}
	return r >= '\u2000' && r <= '\u200a'
}
func headerDefault(r *http.Request, name string) string {
	if v := r.Header.Get(name); v != "" {
		return v
	}
	return "unknown"
}
func requestIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if forwarded := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-For"), ",")[0]); forwarded != "" {
			return forwarded
		}
	}
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil && ip != "" {
		return ip
	}
	if net.ParseIP(r.RemoteAddr) != nil {
		return r.RemoteAddr
	}
	return "unknown"
}

func issueLogin(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, store LoginRepository, user LoginAccount, config RefreshConfig) {
	id, err := randomUUID()
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	id = "sess_" + id
	accessJTI, err := randomUUID()
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	refreshJTI, err := randomUUID()
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	claims := auth.Claims{UserID: user.UserID, UserName: user.Username, SessionID: id, JTI: accessJTI, Kind: auth.Access}
	access, err := codec.Sign(claims, int64(config.AccessSeconds))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	claims.Kind = auth.Refresh
	claims.JTI = refreshJTI
	refresh, err := codec.Sign(claims, int64(config.RefreshSeconds))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	now := config.clock().UTC().Truncate(time.Millisecond)
	session := LoginSession{UserID: user.UserID, SessionID: id, AccessJTI: accessJTI, RefreshHash: refreshHash(refresh), DeviceInfo: headerDefault(r, "X-Device-Info"), DeviceFingerprint: headerDefault(r, "X-Device-Fingerprint"), IPAddress: requestIP(r, config.TrustProxy), UserAgent: headerDefault(r, "User-Agent"), AccessExpiresAt: now.Add(time.Duration(config.AccessSeconds) * time.Second), RefreshExpiresAt: now.Add(time.Duration(config.RefreshSeconds) * time.Second)}
	known, err := store.KnownLoginDevice(r.Context(), user.UserID, session.DeviceFingerprint)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if err = store.InsertLoginSession(r.Context(), session); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if err = store.UpdateLastLogin(r.Context(), user.UserID); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !known {
		_ = store.RecordLoginAlert(r.Context(), session)
	}
	profile, found, err := store.SelfProfile(r.Context(), user.UserID)
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
	for _, c := range []struct {
		name, value string
		age         int
	}{{"access_token", access, config.AccessSeconds}, {"refresh_token", refresh, config.RefreshSeconds}} {
		http.SetCookie(w, &http.Cookie{Name: c.name, Value: c.value, Path: "/", MaxAge: c.age, HttpOnly: true, Secure: config.CookieSecure, SameSite: http.SameSiteLaxMode})
	}
	const iso = "2006-01-02T15:04:05.000Z"
	respond(w, 200, 200, "login success", map[string]interface{}{"two_factor_required": false, "user": profile, "tokens": map[string]string{"session_id": id, "access_token": access, "refresh_token": refresh, "access_token_expires_at": session.AccessExpiresAt.Format(iso), "refresh_token_expires_at": session.RefreshExpiresAt.Format(iso)}})
}
