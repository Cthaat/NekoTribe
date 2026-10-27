package server

import (
	"context"
	"net/http"
	"net/url"
	"regexp"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

// LogoutRepository revokes only the session identified by a current credential.
type LogoutRepository interface {
	RevokeRefresh(context.Context, auth.Claims, string) (int64, error)
	RevokeAccess(context.Context, auth.Claims) (int64, error)
}

var strictBearer = regexp.MustCompile(`(?i)^Bearer\s+(\S+)$`)

func logoutAccessToken(r *http.Request) string {
	if cookie, err := r.Cookie("access_token"); err == nil && cookie.Value != "" {
		value, err := url.PathUnescape(cookie.Value)
		if err == nil {
			return value
		}
		return cookie.Value
	}
	if match := strictBearer.FindStringSubmatch(r.Header.Get("Authorization")); len(match) == 2 {
		return match[1]
	}
	return ""
}

func logoutCurrent(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) {
	refresh := refreshToken(r)
	var claims auth.Claims
	var err error
	if refresh != "" {
		claims, err = codec.VerifyRefreshForRotation(refresh)
	} else {
		claims, err = codec.Verify(logoutAccessToken(r), auth.Access)
	}
	if err == nil {
		store, ok := repository.(LogoutRepository)
		if !ok {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		if refresh != "" {
			_, err = store.RevokeRefresh(r.Context(), claims, refreshHash(refresh))
		} else {
			_, err = store.RevokeAccess(r.Context(), claims)
		}
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
	}
	for _, name := range []string{"access_token", "refresh_token"} {
		http.SetCookie(w, &http.Cookie{Name: name, Value: "", Path: "/", MaxAge: -1})
	}
	respond(w, 200, 200, "logout success", nil)
}
