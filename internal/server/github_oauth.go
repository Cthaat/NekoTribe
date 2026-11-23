package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

const (
	githubLoginPurpose = "login"
	githubLinkPurpose  = "link"
	githubCallbackPath = "/api/v2/auth/oauth/github/callback"
	githubLinkPath     = "/api/v2/users/me/oauth/github"
	githubLoginFlows   = "/api/v2/auth/oauth/github/login/flows"
	githubLinkFlows    = githubLinkPath + "/flows"
	githubOAuthStale   = "GitHub 授权无效或已过期"
)

type githubOAuthPolicy struct {
	TTLSeconds, NonceBytes, ProviderTimeoutMs, ProviderBodyMaxBytes int
	Endpoints                                                       struct{ Authorize, Exchange, Profile string }
	SQL                                                             map[string]string
}

var githubOAuth = func() githubOAuthPolicy {
	var policy githubOAuthPolicy
	if json.Unmarshal(contracts.GitHubOAuth, &policy) != nil || policy.NonceBytes != 32 ||
		policy.TTLSeconds <= 0 || policy.ProviderTimeoutMs <= 0 || policy.ProviderBodyMaxBytes <= 0 ||
		policy.Endpoints.Authorize == "" || policy.Endpoints.Exchange == "" || policy.Endpoints.Profile == "" {
		panic("invalid GitHub OAuth contract")
	}
	return policy
}()

var (
	errGitHubInvalid     = errors.New("invalid GitHub OAuth request")
	errGitHubUnverified  = errors.New("GitHub OAuth flow unverified")
	errGitHubUnavailable = errors.New("GitHub OAuth unavailable")
	errGitHubMissing     = errors.New("GitHub link missing")
	errGitHubConflict    = errors.New("GitHub link conflict")
	githubCodePattern    = regexp.MustCompile(`^[A-Za-z0-9_-]{1,512}$`)
	githubTokenPattern   = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

type githubOAuthProvider struct {
	clientID, clientSecret, redirect string
	client                           *http.Client
}

func configuredGitHubOAuth(clientID, secret, redirect string) *githubOAuthProvider {
	clientID, secret, redirect = strings.TrimSpace(clientID), strings.TrimSpace(secret), strings.TrimSpace(redirect)
	target, err := url.Parse(redirect)
	if clientID == "" || secret == "" || err != nil || target.Hostname() == "" || target.User != nil ||
		target.EscapedPath() != githubCallbackPath || target.RawQuery != "" || target.ForceQuery ||
		strings.Contains(redirect, "#") || strings.HasSuffix(target.Host, ":") ||
		(target.Scheme != "https" && !(target.Scheme == "http" && strings.EqualFold(target.Hostname(), "localhost"))) {
		return nil
	}
	if port := target.Port(); port != "" {
		value, err := strconv.Atoi(port)
		if err != nil || value < 1 || value > 65535 {
			return nil
		}
	}
	timeout := time.Duration(githubOAuth.ProviderTimeoutMs) * time.Millisecond
	return &githubOAuthProvider{clientID: clientID, clientSecret: secret, redirect: redirect, client: &http.Client{
		Transport: &http.Transport{
			DialContext:            (&net.Dialer{Timeout: timeout}).DialContext,
			ForceAttemptHTTP2:      true,
			IdleConnTimeout:        30 * time.Second,
			MaxResponseHeaderBytes: 32 << 10,
		},
		Timeout:       timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

type githubFlowStart struct {
	ID               string `json:"flow_id"`
	Key              string `json:"flow_key"`
	AuthorizationURL string `json:"authorization_url"`
	ExpiresIn        int    `json:"expires_in"`
}

type githubFlowSecrets struct {
	id, key, state, verifier string
}

func newGitHubFlowSecrets() (githubFlowSecrets, error) {
	var flow githubFlowSecrets
	for _, value := range []*string{&flow.id, &flow.key, &flow.state, &flow.verifier} {
		b := make([]byte, githubOAuth.NonceBytes)
		if _, err := rand.Read(b); err != nil {
			return githubFlowSecrets{}, errSessionStore
		}
		*value = base64.RawURLEncoding.EncodeToString(b)
	}
	return flow, nil
}

func validGitHubNonce(value string) bool {
	if len(value) != base64.RawURLEncoding.EncodedLen(githubOAuth.NonceBytes) {
		return false
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(value)
	return err == nil && len(raw) == githubOAuth.NonceBytes
}

func (p *githubOAuthProvider) authorization(flow githubFlowSecrets) githubFlowStart {
	challenge := sha256.Sum256([]byte(flow.verifier))
	params := url.Values{
		"client_id": {p.clientID}, "redirect_uri": {p.redirect}, "state": {flow.state},
		"scope": {""}, "code_challenge": {base64.RawURLEncoding.EncodeToString(challenge[:])},
		"code_challenge_method": {"S256"}, "allow_signup": {"false"},
	}
	return githubFlowStart{flow.id, flow.key, githubOAuth.Endpoints.Authorize + "?" + params.Encode(), githubOAuth.TTLSeconds}
}

type githubIdentity struct {
	ID    string `json:"github_user_id"`
	Login string `json:"github_login"`
}

func validGitHubIdentity(id githubIdentity) bool {
	n, err := strconv.ParseInt(id.ID, 10, 64)
	return err == nil && n > 0 && n <= 9007199254740991 && strconv.FormatInt(n, 10) == id.ID &&
		id.Login != "" && strings.TrimSpace(id.Login) == id.Login && utf8.RuneCountInString(id.Login) <= 80 &&
		strings.IndexFunc(id.Login, unicode.IsControl) < 0
}

func (p *githubOAuthProvider) identity(ctx context.Context, code, verifier string) (githubIdentity, error) {
	var zero githubIdentity
	ctx, cancel := context.WithTimeout(ctx, time.Duration(githubOAuth.ProviderTimeoutMs)*time.Millisecond)
	defer cancel()
	params := url.Values{
		"client_id": {p.clientID}, "client_secret": {p.clientSecret}, "redirect_uri": {p.redirect},
		"code": {code}, "code_verifier": {verifier},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, githubOAuth.Endpoints.Exchange, strings.NewReader(params.Encode()))
	if err != nil {
		return zero, errGitHubUnverified
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "NekoTribe OAuth")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var token struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if !p.readJSON(req, &token) || token.Error != "" || len(token.AccessToken) > 2048 ||
		!githubTokenPattern.MatchString(token.AccessToken) {
		return zero, errGitHubUnverified
	}

	req, err = http.NewRequestWithContext(ctx, http.MethodGet, githubOAuth.Endpoints.Profile, nil)
	if err != nil {
		return zero, errGitHubUnverified
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "NekoTribe OAuth")
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)
	var profile struct {
		ID    int64  `json:"id"`
		Login string `json:"login"`
	}
	if !p.readJSON(req, &profile) {
		return zero, errGitHubUnverified
	}
	id := githubIdentity{strconv.FormatInt(profile.ID, 10), strings.TrimSpace(profile.Login)}
	if !validGitHubIdentity(id) {
		return zero, errGitHubUnverified
	}
	return id, nil
}

func (p *githubOAuthProvider) readJSON(req *http.Request, target any) bool {
	resp, err := p.client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	limit := int64(githubOAuth.ProviderBodyMaxBytes)
	if resp.StatusCode != http.StatusOK || resp.ContentLength > limit {
		return false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	return err == nil && int64(len(body)) <= limit && json.Unmarshal(body, target) == nil
}
