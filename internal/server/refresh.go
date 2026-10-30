package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

// Rotation contains only server-generated identifiers and hashes, never tokens.
type Rotation struct {
	UserID                                 int64
	SessionID, OldHash, NewHash, AccessJTI string
	AccessExpiresAt, RefreshExpiresAt      time.Time
}

type RefreshRepository interface {
	Rotate(context.Context, Rotation) (int64, error)
}

type RefreshConfig struct {
	AccessSeconds, RefreshSeconds int
	CookieSecure                  bool
	TrustProxy                    bool
	Storage                       StorageURLPolicy
	LocalStorage                  LocalStorageConfig
	NotificationEvents            NotificationEventSource
	NotificationPublisher         NotificationEventPublisher
	PresencePublisher             presencePublisher
	otpMailer                     otpMailSender
	clock                         func() time.Time
}

func (RefreshConfig) String() string   { return "RefreshConfig [redacted]" }
func (RefreshConfig) GoString() string { return "RefreshConfig [redacted]" }

func (c RefreshConfig) defaults() RefreshConfig {
	if c.AccessSeconds == 0 {
		c.AccessSeconds = 900
	}
	if c.RefreshSeconds == 0 {
		c.RefreshSeconds = 2592000
	}
	if c.clock == nil {
		c.clock = time.Now
	}
	return c
}

func refreshHash(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}

func randomUUID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	s := hex.EncodeToString(value[:])
	return s[:8] + "-" + s[8:12] + "-" + s[12:16] + "-" + s[16:20] + "-" + s[20:], nil
}

func refreshToken(r *http.Request) string {
	if cookie, err := r.Cookie("refresh_token"); err == nil && cookie.Value != "" {
		value, err := url.PathUnescape(cookie.Value)
		if err != nil {
			value = cookie.Value
		}
		return strings.TrimSpace(value)
	}
	// H3 readBody returns text/* as a string; v2Body requires an object.
	if strings.HasPrefix(r.Header.Get("Content-Type"), "text/") {
		return ""
	}
	mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaType == "application/x-www-form-urlencoded" {
		b, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		if err != nil || len(b) > 1<<20 {
			return ""
		}
		values, err := url.ParseQuery(string(b))
		if err != nil || len(values["refresh_token"]) != 1 {
			return ""
		}
		return strings.TrimSpace(values.Get("refresh_token"))
	}
	var body struct {
		RefreshToken string `json:"refresh_token"`
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(b) > 1<<20 || json.Unmarshal(b, &body) != nil {
		return ""
	}
	return strings.TrimSpace(body.RefreshToken)
}

func refreshCurrent(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
	unauthorized := func() { respond(w, 401, 40101, "未认证或 token 无效", nil) }
	token := refreshToken(r)
	if token == "" {
		unauthorized()
		return
	}
	claims, err := codec.VerifyRefreshForRotation(token)
	if err != nil {
		unauthorized()
		return
	}
	store, ok := repository.(RefreshRepository)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
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
	accessClaims := claims
	accessClaims.Kind, accessClaims.JTI = auth.Access, accessJTI
	refreshClaims := claims
	refreshClaims.Kind, refreshClaims.JTI = auth.Refresh, refreshJTI
	access, err := codec.Sign(accessClaims, int64(config.AccessSeconds))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	newRefresh, err := codec.Sign(refreshClaims, int64(config.RefreshSeconds))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	now := config.clock().UTC().Truncate(time.Millisecond)
	rotation := Rotation{UserID: claims.UserID, SessionID: claims.SessionID, OldHash: refreshHash(token), NewHash: refreshHash(newRefresh), AccessJTI: accessJTI,
		AccessExpiresAt: now.Add(time.Duration(config.AccessSeconds) * time.Second), RefreshExpiresAt: now.Add(time.Duration(config.RefreshSeconds) * time.Second)}
	count, err := store.Rotate(r.Context(), rotation)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if count != 1 {
		unauthorized()
		return
	}
	for _, cookie := range []struct {
		name, value string
		maxAge      int
	}{{"access_token", access, config.AccessSeconds}, {"refresh_token", newRefresh, config.RefreshSeconds}} {
		http.SetCookie(w, &http.Cookie{Name: cookie.name, Value: cookie.value, Path: "/", MaxAge: cookie.maxAge, HttpOnly: true, Secure: config.CookieSecure, SameSite: http.SameSiteLaxMode})
	}
	const iso = "2006-01-02T15:04:05.000Z"
	respond(w, 200, 200, "success", map[string]string{"session_id": claims.SessionID, "access_token": access, "refresh_token": newRefresh,
		"access_token_expires_at": rotation.AccessExpiresAt.Format(iso), "refresh_token_expires_at": rotation.RefreshExpiresAt.Format(iso)})
}
