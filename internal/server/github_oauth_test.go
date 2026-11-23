package server

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"database/sql/driver"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type githubTransportFunc func(*http.Request) (*http.Response, error)

func (f githubTransportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func githubResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

type githubFixtureFlow struct {
	id, stateHash, keyHash, verifier, purpose, session string
	ownerID                                            any
	status                                             string
	githubID, login                                    any
}

type githubOracleFixture struct {
	schemaFixtureConnector
	driverState
	flow             githubFixtureFlow
	link             *githubOAuthLink
	expired, dormant bool
	passkeys         int64
	hash             string
}

type githubFixtureConn struct {
	*testConn
	f                                  *githubOracleFixture
	active, callback, complete, locked bool
	touched                            bool
	flow                               githubFixtureFlow
	link                               *githubOAuthLink
}

func (f *githubOracleFixture) Connect(context.Context) (driver.Conn, error) {
	return &githubFixtureConn{testConn: &testConn{&f.driverState}, f: f}, nil
}

func (c *githubFixtureConn) Begin() (driver.Tx, error) {
	c.active, c.callback, c.complete, c.locked, c.touched = true, false, false, false, false
	c.flow, c.link = c.f.flow, c.f.link
	return c, nil
}

func (c *githubFixtureConn) Commit() error {
	c.active = false
	c.f.flow, c.f.link = c.flow, c.link
	c.f.commits++
	return nil
}

func (c *githubFixtureConn) Rollback() error {
	c.active = false
	c.f.rollbacks++
	return nil
}

func (c *githubFixtureConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	f := c.f
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	row := func(values ...driver.Value) (driver.Rows, error) { return &alertRows{values: values}, nil }
	empty := func() (driver.Rows, error) { return emptyRows{&f.driverState}, nil }
	switch query {
	case githubOAuth.SQL["callbackLock"]:
		c.callback = c.active && c.flow.status == "pending" && !f.expired && bind("state_hash") == c.flow.stateHash
		if !c.callback {
			return empty()
		}
		return row(c.flow.id, c.flow.verifier)
	case githubOAuth.SQL["completeLock"]:
		c.complete = c.active && !f.expired && c.flow.id != "" && bind("flow_id") == c.flow.id &&
			bind("purpose") == c.flow.purpose && bind("flow_key_hash") == c.flow.keyHash &&
			(c.flow.purpose == "login" || (bind("owner_user_id") == c.flow.ownerID && bind("owner_session_id") == c.flow.session))
		if !c.complete {
			return empty()
		}
		return row(c.flow.status, c.flow.githubID, c.flow.login)
	case lockLoginUserSQL, passkeyAuth.SQL["lockOwner"]:
		c.locked = c.active && bind("user_id") == int64(42)
		if !c.locked {
			return empty()
		}
		if query == lockLoginUserSQL {
			return row(int64(42))
		}
		return row(int64(42), f.hash)
	case passkeyAuth.SQL["owner"]:
		if !c.locked {
			return nil, errors.New("login account read outside owner lock")
		}
		if f.dormant {
			return row(int64(42), "tester", nil, f.hash, int64(0), "inactive")
		}
		return row(int64(42), "tester", nil, f.hash, int64(1), "active")
	case githubOAuth.SQL["linkForUser"], githubOAuth.SQL["linkForGitHub"]:
		link := f.link
		if c.active {
			link = c.link
		}
		if link == nil || (bind("user_id") != link.userID && bind("github_user_id") != link.ID) {
			return empty()
		}
		return row(link.userID, link.ID, link.Login, passkeyDateFixture)
	case githubOAuth.SQL["passkeyCount"]:
		if !c.locked || !c.touched || bind("user_id") != int64(42) {
			return nil, errors.New("counted fallback without owner and session lock")
		}
		return row(f.passkeys)
	default:
		return (&schemaFixtureConn{f.schemaFixtureConnector}).QueryContext(ctx, query, args)
	}
}

func (c *githubFixtureConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	f := c.f
	if query == githubOAuth.SQL["callbackFinish"] {
		if !c.active || c.callback {
			return nil, errors.New("callback outcome incorrectly used claimed transaction")
		}
		if f.expired || c.flow.status != "checking" || bind("flow_id") != c.flow.id {
			return driver.RowsAffected(0), nil
		}
		c.flow.status, c.flow.verifier = bind("status").(string), ""
		c.flow.githubID, c.flow.login = bind("github_user_id"), bind("github_login")
		return driver.RowsAffected(1), nil
	}
	if !c.active {
		return nil, errors.New("GitHub write without transaction")
	}
	switch query {
	case githubOAuth.SQL["prune"]:
		return driver.RowsAffected(0), nil
	case githubOAuth.SQL["begin"]:
		if bind("ttl_seconds") != int64(githubOAuth.TTLSeconds) {
			return nil, errors.New("wrong flow expiry")
		}
		c.flow = githubFixtureFlow{
			id: bind("flow_id").(string), stateHash: bind("state_hash").(string), keyHash: bind("flow_key_hash").(string),
			verifier: bind("pkce_verifier").(string), purpose: bind("purpose").(string), ownerID: bind("owner_user_id"), status: "pending",
		}
		c.flow.session, _ = bind("owner_session_id").(string)
	case githubOAuth.SQL["callbackClaim"]:
		if !c.callback || bind("flow_id") != c.flow.id {
			return nil, errors.New("claim missing callback row lock")
		}
		c.flow.status = "checking"
	case githubOAuth.SQL["completeConsume"]:
		if !c.complete || bind("flow_id") != c.flow.id || c.flow.status == "pending" || c.flow.status == "checking" {
			return nil, errors.New("consumption missing completed row lock")
		}
		c.flow = githubFixtureFlow{}
	case TouchSQL:
		if !c.locked || bind("user_id") != int64(42) || bind("session_id") == nil || bind("access_jti") == nil {
			return nil, errors.New("link mutation without owner and session lock")
		}
		c.touched = true
	case githubOAuth.SQL["linkCreate"], githubOAuth.SQL["linkRemove"]:
		if !c.locked || !c.touched || bind("user_id") != int64(42) {
			return nil, errors.New("link mutation without active owner session")
		}
		if query == githubOAuth.SQL["linkRemove"] {
			c.link = nil
			break
		}
		if c.link != nil {
			return nil, errors.New("ORA-00001: GitHub identity already attached")
		}
		c.link = &githubOAuthLink{githubIdentity{bind("github_user_id").(string), bind("github_login").(string)}, 42, ""}
	default:
		return nil, errors.New("unexpected GitHub fixture write")
	}
	return driver.RowsAffected(1), nil
}

type githubHTTPFixture struct {
	*factorFixture
	sessions *memorySessions
	oracle   OracleSessions
}

func (f *githubHTTPFixture) Touch(ctx context.Context, claims auth.Claims) (int64, error) {
	return f.sessions.Touch(ctx, claims)
}

func (f *githubHTTPFixture) openGitHubOAuth(ctx context.Context) (githubOAuthPersistence, error) {
	return f.oracle.openGitHubOAuth(ctx)
}

func TestGitHubOAuthHTTPFlowAndLoginLifecycle(t *testing.T) {
	fixtureDB := &githubOracleFixture{schemaFixtureConnector: postFeatureSchemaFixture(t, contracts.GitHubOAuthSchemaCatalog)}
	db := sql.OpenDB(fixtureDB)
	t.Cleanup(func() { _ = db.Close() })
	codec, tokens := fixture(t)
	base, _, _ := newLoginFixture(t)
	store := &githubHTTPFixture{&factorFixture{loginFixtureStore: base}, store(), OracleSessions{db}}
	provider := configuredGitHubOAuth("fixture-client", "fixture-secret", "https://example.com"+githubCallbackPath)
	other, err := codec.Sign(auth.Claims{UserID: 42, UserName: "tester", SessionID: "peer", JTI: "peer-jti", Kind: auth.Access}, 900)
	if err != nil {
		t.Fatal(err)
	}
	owner := tokens["access-hs256"]
	exchanges := 0
	var providerID = "9007199254740991"
	provider.client.Transport = githubTransportFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.String() {
		case githubOAuth.Endpoints.Exchange:
			exchanges++
			if fixtureDB.flow.status != "checking" || r.Method != "POST" || r.ParseForm() != nil ||
				r.Form.Get("client_secret") != "fixture-secret" || r.Form.Get("code") != "fixture-code" ||
				r.Form.Get("code_verifier") != fixtureDB.flow.verifier || r.Header.Get("Accept") != "application/json" {
				t.Fatal("provider exchange ran before committing claim or sent wrong PKCE form")
			}
			return githubResponse(200, `{"access_token":"fixture-provider-token"}`), nil
		case githubOAuth.Endpoints.Profile:
			if r.Method != "GET" || r.Header.Get("Authorization") != "Bearer fixture-provider-token" {
				t.Fatal("profile request did not use the exchanged bearer")
			}
			return githubResponse(200, `{"id":`+providerID+`,"login":"octocat","email":"irrelevant@example.com"}`), nil
		default:
			t.Fatalf("unexpected provider endpoint %q", r.URL)
			return nil, errors.New("unexpected endpoint")
		}
	})
	h := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{githubOAuth: provider,
		clock: func() time.Time { return time.Unix(1700000000, 0) }})
	send := func(method, path, token, body string, status int) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != status || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s returned %d, want %d: %s", method, w.Code, status, w.Body)
		}
		return w
	}
	start := func(path, token string) (finish, state, body string) {
		t.Helper()
		w := send("POST", path, token, "", 200)
		var reply struct{ Data githubFlowStart }
		if json.Unmarshal(w.Body.Bytes(), &reply) != nil {
			t.Fatal("malformed start response")
		}
		data, flow := reply.Data, fixtureDB.flow
		u, err := url.Parse(data.AuthorizationURL)
		if err != nil {
			t.Fatal(err)
		}
		q := u.Query()
		secret := q.Get("state")
		sum := sha256.Sum256([]byte(flow.verifier))
		if u.Scheme != "https" || u.Host != "github.com" || u.Path != "/login/oauth/authorize" ||
			!validGitHubNonce(data.ID) || !validGitHubNonce(data.Key) || !validGitHubNonce(secret) || !validGitHubNonce(flow.verifier) ||
			data.ID == data.Key || data.ID == secret || data.ID == flow.verifier || data.Key == secret ||
			data.Key == flow.verifier || secret == flow.verifier || data.ExpiresIn != 300 ||
			q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") != base64.RawURLEncoding.EncodeToString(sum[:]) ||
			q.Get("scope") != "" || flow.keyHash != refreshHash(data.Key) || flow.stateHash != refreshHash(secret) {
			t.Fatal("invalid flow seeds, storage or authorization request")
		}
		return path + "/" + data.ID + "/complete", secret, fmt.Sprintf(`{"flow_key":%q}`, data.Key)
	}
	callback := func(state, params string, status int) {
		t.Helper()
		w := send("GET", githubCallbackPath+"?state="+state+"&"+params, "", "", status)
		if w.Body.String() != githubCallbackHTML || w.Header().Get("Referrer-Policy") != "no-referrer" ||
			w.Header().Get("Content-Security-Policy") == "" || w.Header().Get("Content-Type") != "text/html; charset=utf-8" ||
			len(w.Result().Cookies()) != 0 {
			t.Fatal("callback returned data or lacked security headers")
		}
	}

	send("GET", githubLinkPath, "", "", 401)
	send("GET", githubLinkPath, owner, "", 200)
	send("DELETE", githubLinkPath, owner, "", 404)
	finish, state, body := start(githubLinkFlows, owner)
	callback("invalid", "code=fixture-code", 400)
	callback(strings.Repeat("A", 43), "code=fixture-code", 401)
	callback(state, "code=invalid+whitespace", 400)
	if response := send("POST", finish, owner, body, 200); !strings.Contains(response.Body.String(), `"status":"pending"`) {
		t.Fatal("pending callback consumed the flow")
	}
	callback(state, "code=fixture-code", 200)
	callback(state, "code=fixture-code", 401)
	send("POST", finish, other, body, 401)
	send("POST", finish, owner, strings.TrimSuffix(body, "}")+`,"remember_me":false}`, 400)
	send("POST", finish, owner, `{"flow_key":"`+strings.Repeat("A", 43)+`"}`, 401)
	linked := send("POST", finish, owner, body, 200)
	if exchanges != 1 || !strings.Contains(linked.Body.String(), `"github_user_id":"9007199254740991"`) || fixtureDB.link == nil ||
		strings.Contains(linked.Body.String(), "irrelevant@example.com") {
		t.Fatal("link receipt did not contain just the verified account identity")
	}
	send("POST", finish, owner, body, 401)
	send("GET", githubLinkPath, owner, "", 200)

	finish, state, body = start(githubLinkFlows, owner)
	callback(state, "code=fixture-code", 200)
	send("POST", finish, owner, body, 200)
	finish, state, body = start(githubLinkFlows, owner)
	providerID = "99"
	callback(state, "code=fixture-code", 200)
	send("POST", finish, owner, body, 409)
	providerID = "9007199254740991"

	beforeDenial := exchanges
	finish, state, body = start(githubLoginFlows, "")
	callback(state, "error=access_denied&error_description=fixture", 401)
	if fixtureDB.flow.status != "failed" || fixtureDB.flow.verifier != "" || exchanges != beforeDenial {
		t.Fatal("denied callback did not consume and clear its verifier")
	}
	send("POST", finish, "", body, 401)
	finish, state, body = start(githubLoginFlows, "")
	providerID = "9007199254740992"
	callback(state, "code=fixture-code", 401)
	send("POST", finish, "", body, 401)
	providerID = "9007199254740991"
	finish, state, body = start(githubLoginFlows, "")
	fixtureDB.expired = true
	callback(state, "code=fixture-code", 401)
	send("POST", finish, "", body, 401)
	fixtureDB.expired = false
	finish, state, body = start(githubLoginFlows, "")
	callback(state, "code=fixture-code", 200)
	fixtureDB.dormant = true
	send("POST", finish, "", body, 403)
	fixtureDB.dormant = false
	finish, state, body = start(githubLoginFlows, "")
	callback(state, "code=fixture-code", 200)
	login := send("POST", finish, "", body, 200)
	if len(login.Result().Cookies()) != 2 || len(store.inserted) != 1 || store.alertCount != 1 ||
		!strings.Contains(login.Body.String(), `"status":"completed","login":{"tokens"`) {
		t.Fatal("verified sign-in diverged from the standard cookie, response or alert flow")
	}
	send("POST", finish, "", body, 401)
	store.twoFactor = true
	finish, state, body = start(githubLoginFlows, "")
	callback(state, "code=fixture-code", 200)
	login = send("POST", finish, "", strings.TrimSuffix(body, "}")+`,"remember_me":true}`, 200)
	if store.challenge.ID == "" || !store.challenge.Remember || len(login.Result().Cookies()) != 0 ||
		!strings.Contains(login.Body.String(), `"two_factor_required":true`) || len(store.inserted) != 1 {
		t.Fatal("verified sign-in diverged from the standard 2FA flow")
	}

	withNoProvider := NewHandler(codec, store, CorsPolicy{})
	readWithoutProvider := httptest.NewRequest("GET", githubLinkPath, nil)
	readWithoutProvider.Header.Set("Authorization", "Bearer "+owner)
	withoutConfig := httptest.NewRecorder()
	withNoProvider.ServeHTTP(withoutConfig, readWithoutProvider)
	if withoutConfig.Code != 200 || !strings.Contains(withoutConfig.Body.String(), `"github_login":"octocat"`) {
		t.Fatal("the owner could not see the existing link without provider credentials")
	}
	withoutConfig = httptest.NewRecorder()
	withNoProvider.ServeHTTP(withoutConfig, httptest.NewRequest("POST", githubLoginFlows, nil))
	if withoutConfig.Code != 503 {
		t.Fatal("an authorization flow was started without provider credentials")
	}

	send("DELETE", githubLinkPath, owner, "", 409)
	fixtureDB.passkeys = 1
	send("DELETE", githubLinkPath, owner, "", 200)
	if fixtureDB.link != nil {
		t.Fatal("link was not removed with a Passkey fallback")
	}
	finish, state, body = start(githubLoginFlows, "")
	callback(state, "code=fixture-code", 200)
	send("POST", finish, "", body, 401)
	delete(fixtureDB.snapshot["indexes"].(map[string]any), "IDX_GITHUB_OAUTH_FLOW_EXPIRY")
	send("POST", githubLoginFlows, "", "", 503)
	callback(state, "code=fixture-code", 503)
}

func TestGitHubOAuthProviderBoundsAndConfig(t *testing.T) {
	for _, redirect := range []string{
		"http://example.com" + githubCallbackPath, "https://name@example.com" + githubCallbackPath,
		"https://example.com" + githubCallbackPath + "?", "https://example.com/other",
		"https://example.com" + githubCallbackPath + "#secret", "http://localhost:65536" + githubCallbackPath,
	} {
		if configuredGitHubOAuth("client", "secret", redirect) != nil {
			t.Fatalf("accepted unsupported redirect %s", redirect)
		}
	}
	provider := configuredGitHubOAuth("client", "secret", "http://localhost:3000"+githubCallbackPath)
	for _, scenario := range []struct {
		status int
		body   string
	}{
		{307, "redirect"}, {200, strings.Repeat(" ", githubOAuth.ProviderBodyMaxBytes+1)},
		{200, `{"error":"bad_verification_code","access_token":"unexpected"}`},
		{200, `{"access_token":"invalid\r\nauth"}`},
	} {
		calls := 0
		provider.client.Transport = githubTransportFunc(func(r *http.Request) (*http.Response, error) {
			calls++
			if deadline, ok := r.Context().Deadline(); !ok || time.Until(deadline) > 8*time.Second {
				t.Fatal("provider request lacked deadline")
			}
			response := githubResponse(scenario.status, scenario.body)
			response.Header.Set("Location", "https://example.com")
			return response, nil
		})
		if _, err := provider.identity(context.Background(), "code", "verifier"); !errors.Is(err, errGitHubUnverified) || calls != 1 {
			t.Fatalf("invalid exchange returned %v after %d calls", err, calls)
		}
	}
}
