package server

import (
	"context"
	"encoding/json"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

type SessionRepository interface {
	Touch(context.Context, auth.Claims) (int64, error)
	Revoke(context.Context, int64, string) (int64, error)
	RevokeOthers(context.Context, int64, string) (int64, error)
}

type CorsPolicy struct {
	Origins   []string
	Localhost bool
}

func NewHandler(codec *auth.TokenManager, repository SessionRepository, cors CorsPolicy) http.Handler {
	return NewHandlerWithConfig(codec, repository, cors, RefreshConfig{})
}

func NewHandlerWithConfig(codec *auth.TokenManager, repository SessionRepository, cors CorsPolicy, refresh RefreshConfig) http.Handler {
	refresh = refresh.defaults()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if preflight(w, r, cors) {
			return
		}
		if r.Method == http.MethodGet && r.URL.EscapedPath() == "/api/health" {
			respond(w, 200, 200, "ok", map[string]string{"status": "ok", "service": "nekotribe-go"})
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/tokens" && r.Method == http.MethodPost {
			login(w, r, codec, repository, refresh)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/otp/verification" && r.Method == http.MethodPost {
			verifyOTP(w, r, repository, refresh)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/otp" && r.Method == http.MethodPost {
			createOTP(w, r, repository, refresh)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/registration" && r.Method == http.MethodPost {
			register(w, r, repository, refresh)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/password-reset" && r.Method == http.MethodPost {
			passwordReset(w, r, repository)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/two-factor/challenges" && r.Method == http.MethodPost {
			completeTwoFactor(w, r, codec, repository, refresh, "")
			return
		}
		const challengesPrefix = "/api/v2/auth/two-factor/challenges/"
		if strings.HasPrefix(r.URL.EscapedPath(), challengesPrefix) && r.Method == http.MethodPost {
			id := strings.TrimPrefix(r.URL.EscapedPath(), challengesPrefix)
			if id == "" || strings.Contains(id, "/") {
				respond(w, 404, 40404, "API route not found", nil)
				return
			}
			completeTwoFactor(w, r, codec, repository, refresh, id)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/tokens/current" {
			switch r.Method {
			case http.MethodPatch:
				refreshCurrent(w, r, codec, repository, refresh)
			case http.MethodDelete:
				logoutCurrent(w, r, codec, repository)
			default:
				w.Header().Set("Allow", "PATCH, DELETE, OPTIONS")
				respond(w, 405, 40501, "Method not allowed", nil)
			}
			return
		}
		if r.URL.EscapedPath() == "/api/v2/auth/sessions" && r.Method == http.MethodGet {
			listSessions(w, r, codec, repository)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/users/me" && r.Method == http.MethodPatch {
			updateSelfProfile(w, r, codec, repository, refresh)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/users/me" && r.Method == http.MethodGet {
			getSelfProfile(w, r, codec, repository, refresh)
			return
		}
		if id, ok := publicProfileSegment(r.URL.EscapedPath()); ok && id != "me" && r.Method == http.MethodGet {
			getPublicProfile(w, r, codec, repository, refresh, id)
			return
		}
		if id, ok := postSegment(r.URL.EscapedPath()); ok && r.Method == http.MethodGet {
			getPostDetail(w, r, codec, repository, refresh, id)
			return
		}
		if r.URL.EscapedPath() == "/api/v2/posts" && r.Method == http.MethodGet {
			listPosts(w, r, codec, repository, refresh)
			return
		}
		const prefix = "/api/v2/auth/sessions/"
		path := r.URL.EscapedPath()
		if !strings.HasPrefix(path, prefix) || strings.TrimPrefix(path, prefix) == "" || strings.Contains(strings.TrimPrefix(path, prefix), "/") {
			respond(w, 404, 40404, "API route not found", nil)
			return
		}
		if r.Method != http.MethodDelete {
			w.Header().Set("Allow", "DELETE, OPTIONS")
			respond(w, 405, 40501, "Method not allowed", nil)
			return
		}
		token := accessToken(r)
		if token == "" {
			respond(w, 401, 40101, "请先登录", nil)
			return
		}
		claims, err := codec.Verify(token, auth.Access)
		if err != nil {
			respond(w, 401, 40101, "Token无效或已过期", nil)
			return
		}
		affected, err := repository.Touch(r.Context(), claims)
		if err != nil || affected != 1 {
			respond(w, 401, 40101, "Token无效或已过期", nil)
			return
		}
		id := strings.TrimPrefix(path, prefix)
		if id == "others" {
			n, err := repository.RevokeOthers(r.Context(), claims.UserID, claims.SessionID)
			if err != nil {
				respond(w, 500, 50001, "服务器内部错误", nil)
				return
			}
			respond(w, 200, 200, "other sessions revoked", map[string]int64{"revoked_count": n})
			return
		}
		n, err := repository.Revoke(r.Context(), claims.UserID, id)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		if n == 0 {
			respond(w, 404, 40401, "会话不存在", nil)
			return
		}
		if id == claims.SessionID {
			for _, name := range []string{"access_token", "refresh_token"} {
				http.SetCookie(w, &http.Cookie{Name: name, Value: "", Path: "/", MaxAge: -1})
			}
		}
		respond(w, 200, 200, "session revoked", nil)
	})
}

var bearerPrefix = regexp.MustCompile(`(?i)^Bearer\s+`)

func accessToken(r *http.Request) string {
	if c, err := r.Cookie("access_token"); err == nil && c.Value != "" {
		value, err := url.PathUnescape(c.Value)
		if err == nil {
			return value
		}
		return c.Value
	}
	return strings.TrimSpace(bearerPrefix.ReplaceAllString(r.Header.Get("Authorization"), ""))
}
func respond(w http.ResponseWriter, status, code int, message string, data interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(struct {
		Code    int         `json:"code"`
		Message string      `json:"message"`
		Data    interface{} `json:"data"`
		Meta    interface{} `json:"meta"`
	}{code, message, data, nil})
}

const allowedHeaders = "authorization,content-type,accept,origin,x-requested-with,x-request-id,x-client-platform,x-client-route,x-client-component,x-client-source,x-client-referer,x-device-fingerprint,x-device-info"
const allowedMethods = "GET,POST,PUT,PATCH,DELETE,OPTIONS"

func normalizeOrigin(origin string) string {
	u, e := url.Parse(origin)
	if e != nil || u == nil || u.User != nil || strings.ContainsAny(origin, "?#") || u.Path != "" || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || strings.HasSuffix(u.Host, ":") || origin != strings.TrimSpace(origin) {
		return ""
	}
	if port := u.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 || strconv.Itoa(n) != port {
			return ""
		}
	}
	if u.Host != strings.ToLower(u.Host) || strings.Contains(u.Host, ":80") && u.Scheme == "http" && u.Port() == "80" || u.Scheme == "https" && u.Port() == "443" {
		return ""
	}
	return origin
}
func (p CorsPolicy) allows(origin string) bool {
	if normalizeOrigin(origin) == "" {
		return false
	}
	for _, v := range p.Origins {
		if origin == v {
			return true
		}
	}
	if !p.Localhost {
		return false
	}
	u, _ := url.Parse(origin)
	host := u.Hostname()
	return host == "localhost" || host == "::1" || regexp.MustCompile(`^127(?:\.\d{1,3}){3}$`).MatchString(host)
}
func preflight(w http.ResponseWriter, r *http.Request, p CorsPolicy) bool {
	w.Header().Add("Vary", "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")
	origin := r.Header.Get("Origin")
	valid := p.allows(origin)
	method, hasMethod := r.Header["Access-Control-Request-Method"]
	if r.Method == http.MethodOptions && hasMethod && (len(method) == 0 || !contains(strings.Split(allowedMethods, ","), method[0])) {
		valid = false
	}
	requested, hasHeaders := r.Header["Access-Control-Request-Headers"]
	headers := []string{}
	if r.Method == http.MethodOptions && hasHeaders {
		raw := ""
		if len(requested) > 0 {
			raw = requested[0]
		}
		for _, h := range strings.Split(raw, ",") {
			h = strings.ToLower(strings.TrimSpace(h))
			if !contains(strings.Split(allowedHeaders, ","), h) {
				valid = false
			}
			if !contains(headers, h) {
				headers = append(headers, h)
			}
		}
	}
	if valid {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		w.Header().Set("Access-Control-Allow-Methods", allowedMethods)
		h := allowedHeaders
		if len(headers) > 0 {
			h = strings.Join(headers, ",")
		}
		w.Header().Set("Access-Control-Allow-Headers", h)
		w.Header().Set("Access-Control-Expose-Headers", "content-length,content-type")
		w.Header().Set("Access-Control-Max-Age", "86400")
	}
	if r.Method == http.MethodOptions {
		if origin == "" || valid {
			w.WriteHeader(204)
		} else {
			respond(w, 403, 40301, "Forbidden", nil)
		}
		return true
	}
	return false
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
