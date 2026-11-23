package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type githubOAuthOperation struct{ action, purpose, flowID string }

func githubOAuthPath(method, path string) githubOAuthOperation {
	switch method {
	case http.MethodGet:
		switch path {
		case githubCallbackPath:
			return githubOAuthOperation{action: "callback"}
		case githubLinkPath:
			return githubOAuthOperation{action: "read", purpose: githubLinkPurpose}
		}
	case http.MethodDelete:
		if path == githubLinkPath {
			return githubOAuthOperation{action: "remove", purpose: githubLinkPurpose}
		}
	case http.MethodPost:
		switch path {
		case githubLoginFlows:
			return githubOAuthOperation{action: "begin", purpose: githubLoginPurpose}
		case githubLinkFlows:
			return githubOAuthOperation{action: "begin", purpose: githubLinkPurpose}
		}
		for _, flow := range []struct{ prefix, purpose string }{{githubLoginFlows, githubLoginPurpose}, {githubLinkFlows, githubLinkPurpose}} {
			tail, ok := strings.CutPrefix(path, flow.prefix+"/")
			id, complete := strings.CutSuffix(tail, "/complete")
			if ok && complete && !strings.Contains(id, "/") {
				return githubOAuthOperation{action: "complete", purpose: flow.purpose, flowID: id}
			}
		}
	}
	return githubOAuthOperation{}
}

func readGitHubCompletion(r *http.Request, op githubOAuthOperation) (key string, remember bool, err error) {
	if !validGitHubNonce(op.flowID) {
		return "", false, errGitHubInvalid
	}
	const maxBytes = 4096
	raw, err := io.ReadAll(io.LimitReader(r.Body, maxBytes+1))
	var body map[string]json.RawMessage
	if err != nil || len(raw) > maxBytes || json.Unmarshal(raw, &body) != nil ||
		json.Unmarshal(body["flow_key"], &key) != nil || !validGitHubNonce(key) {
		return "", false, errGitHubInvalid
	}
	for name, value := range body {
		if name == "flow_key" {
			continue
		}
		var flag *bool
		if op.purpose != githubLoginPurpose || name != "remember_me" ||
			json.Unmarshal(value, &flag) != nil || flag == nil {
			return "", false, errGitHubInvalid
		}
		remember = *flag
	}
	return key, remember, nil
}

func gitHubOAuthError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errGitHubInvalid):
		respond(w, 400, 40001, "GitHub 授权参数错误", nil)
	case errors.Is(err, errGitHubUnverified):
		respond(w, 401, 40101, githubOAuthStale, nil)
	case errors.Is(err, errPasskeyOwner):
		respond(w, 403, 40301, "账号不可用", nil)
	case errors.Is(err, errGitHubMissing):
		respond(w, 404, 40401, "GitHub 绑定不存在", nil)
	case errors.Is(err, errGitHubConflict):
		respond(w, 409, 40901, "GitHub 绑定冲突", nil)
	case errors.Is(err, errPasskeyLast):
		respond(w, 409, 40901, "必须保留至少一种登录方式", nil)
	default:
		respond(w, 503, 50301, "GitHub 授权暂不可用", nil)
	}
}

func githubOAuthRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	op := githubOAuthPath(r.Method, r.URL.EscapedPath())
	if op.action == "" {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	store, ok := repo.(githubOAuthStore)
	if op.action == "callback" {
		githubOAuthCallback(w, r, store, config.githubOAuth)
		return true
	}
	owner := githubFlowOwner{purpose: op.purpose}
	if owner.purpose == githubLinkPurpose {
		claims, ok := passkeySession(w, r, codec, repo)
		if !ok {
			return true
		}
		owner.claims = claims
	}
	var key string
	var remember bool
	if op.action == "complete" {
		var err error
		key, remember, err = readGitHubCompletion(r, op)
		if err != nil {
			gitHubOAuthError(w, err)
			return true
		}
	}
	if !ok || (op.action == "begin" || op.action == "complete") && config.githubOAuth == nil {
		gitHubOAuthError(w, errGitHubUnavailable)
		return true
	}
	ctx := r.Context()
	db, err := store.openGitHubOAuth(ctx)
	if err != nil {
		gitHubOAuthError(w, err)
		return true
	}
	switch op.action {
	case "begin":
		flow, err := newGitHubFlowSecrets()
		if err == nil {
			err = db.begin(ctx, owner, flow)
		}
		if err != nil {
			gitHubOAuthError(w, err)
		} else {
			respond(w, 200, 200, "success", config.githubOAuth.authorization(flow))
		}
	case "complete":
		githubOAuthComplete(w, r, codec, repo, db, config, owner, op.flowID, key, remember)
	case "read":
		link, err := db.linkForUser(ctx, owner.claims.UserID)
		if err != nil {
			gitHubOAuthError(w, err)
		} else {
			respond(w, 200, 200, "success", struct {
				Link *githubOAuthLink `json:"link"`
			}{Link: link})
		}
	case "remove":
		if err := db.unlink(ctx, owner.claims); err != nil {
			gitHubOAuthError(w, err)
		} else {
			respond(w, 200, 200, "success", nil)
		}
	}
	return true
}

func githubOAuthComplete(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository,
	db githubOAuthPersistence, config RefreshConfig, owner githubFlowOwner, flowID, key string, remember bool) {
	ctx := r.Context()
	id, pending, err := db.complete(ctx, owner, flowID, key)
	if err != nil {
		gitHubOAuthError(w, err)
		return
	}
	if pending {
		respond(w, 200, 200, "success", map[string]string{"status": "pending"})
		return
	}
	if owner.purpose == githubLinkPurpose {
		link, err := db.link(ctx, owner.claims, id)
		if err != nil {
			gitHubOAuthError(w, err)
			return
		}
		respond(w, 200, 200, "success", struct {
			Status string           `json:"status"`
			Link   *githubOAuthLink `json:"link"`
		}{"completed", link})
		return
	}
	login, ok := repo.(LoginRepository)
	if !ok {
		gitHubOAuthError(w, errGitHubUnavailable)
		return
	}
	user, err := db.loginAccount(ctx, id)
	if err != nil {
		gitHubOAuthError(w, err)
		return
	}
	finishPrimaryLogin(w, r, codec, login, user, user.Username, githubOAuthStale, remember, config,
		func(w http.ResponseWriter, message string, data any) {
			respond(w, 200, 200, message, struct {
				Status string `json:"status"`
				Login  any    `json:"login"`
			}{"completed", data})
		})
}

const githubCallbackHTML = `<!doctype html><html lang="zh"><meta charset="utf-8"><title>NekoTribe</title><main><h1>返回 NekoTribe</h1><p>请在原来的应用或标签页查看授权结果。</p><p>Return to NekoTribe to see the authorization result.</p></main></html>`

func githubOAuthCallback(w http.ResponseWriter, r *http.Request, store githubOAuthStore, provider *githubOAuthProvider) {
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; base-uri 'none'; frame-ancestors 'none'")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(githubOAuthCallbackStatus(r, store, provider))
	_, _ = io.WriteString(w, githubCallbackHTML)
}

func githubOAuthCallbackStatus(r *http.Request, store githubOAuthStore, provider *githubOAuthProvider) int {
	if len(r.URL.RawQuery) > 8192 {
		return http.StatusBadRequest
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(query["state"]) != 1 || !validGitHubNonce(query.Get("state")) {
		return http.StatusBadRequest
	}
	code, denied := query.Get("code"), query.Has("error")
	if denied && (len(query["error"]) != 1 || query.Get("error") == "") ||
		!denied && (len(query["code"]) != 1 || !githubCodePattern.MatchString(code)) {
		return http.StatusBadRequest
	}
	if store == nil || provider == nil {
		return http.StatusServiceUnavailable
	}
	ctx := r.Context()
	db, err := store.openGitHubOAuth(ctx)
	if err != nil {
		return http.StatusServiceUnavailable
	}
	claim, err := db.claimCallback(ctx, query.Get("state"))
	if errors.Is(err, errGitHubUnverified) {
		return http.StatusUnauthorized
	}
	if err != nil {
		return http.StatusServiceUnavailable
	}
	status := http.StatusOK
	var id githubIdentity
	switch {
	case denied:
		status = http.StatusUnauthorized
	case !validGitHubNonce(claim.verifier):
		status = http.StatusUnauthorized
	default:
		id, err = provider.identity(ctx, code, claim.verifier)
		if err != nil {
			status = http.StatusUnauthorized
		}
	}
	// Record the consumed callback outcome even when the browser has gone away.
	finishCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer cancel()
	if err := db.finishCallback(finishCtx, claim.flowID, id); errors.Is(err, errGitHubUnverified) {
		return http.StatusUnauthorized
	} else if err != nil {
		return http.StatusServiceUnavailable
	}
	return status
}
