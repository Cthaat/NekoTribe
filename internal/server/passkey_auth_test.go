package server

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/protocol/webauthncbor"
)

func TestPasskeyRoutesProtectAccountOperations(t *testing.T) {
	h := NewHandler(nil, nil, CorsPolicy{})
	for _, route := range []struct{ method, path string }{
		{http.MethodPost, "/api/v2/auth/passkeys/registration/options"},
		{http.MethodPost, "/api/v2/auth/passkeys/registration/verification"},
		{http.MethodGet, "/api/v2/users/me/passkeys"},
		{http.MethodDelete, "/api/v2/users/me/passkeys/credential"},
	} {
		res := httptest.NewRecorder()
		h.ServeHTTP(res, httptest.NewRequest(route.method, route.path, nil))
		if res.Code != http.StatusUnauthorized || res.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s returned %d: %s", route.method, route.path, res.Code, res.Body)
		}
	}
	for _, path := range []string{
		"/api/v2/auth/passkeys/authentication/options", "/api/v2/auth/passkeys/authentication/verification",
	} {
		res := httptest.NewRecorder()
		h.ServeHTTP(res, httptest.NewRequest(http.MethodPost, path, nil))
		if res.Code != http.StatusServiceUnavailable || res.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s returned %d: %s", path, res.Code, res.Body)
		}
	}
}

func TestPasskeyConfiguredRPAndOrigins(t *testing.T) {
	android := "android:apk-key-hash:" + passkeyEncode(bytes.Repeat([]byte{1}, 32))
	for _, tc := range []struct {
		rp, origin string
		valid      bool
	}{
		{"example.com", "https://login.example.com", true},
		{"localhost", "http://localhost:3000", true},
		{"example.com", android, true},
		{"example.com", "https://login.example.com," + android, true},
		{"", "https://example.com", false},
		{"https://example.com", "https://example.com", false},
		{"example.com", "", false},
		{"example.com", "http://example.com", false},
		{"example.com", "https://*.example.com", false},
		{"example.com", "https://site.example.com/accounts", false},
		{"example.com", "https://site.example.com?key=fake", false},
		{"example.com", android + "=", false},
	} {
		if got := configuredPasskeys(tc.rp, tc.origin) != nil; got != tc.valid {
			t.Errorf("configuration for %s/%s enabled=%t", tc.rp, tc.origin, got)
		}
	}
	if got := passkeyEncode(passkeyUserHandle(42)); got != "AAAAAAAAAAAAAAAAAAAAKg" {
		t.Fatalf("unexpected deterministic user handle %q", got)
	}
}

func passkeyClientJSON(t *testing.T, ceremony, challenge, origin string, cross bool) []byte {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"type": ceremony, "challenge": challenge, "origin": origin, "crossOrigin": cross})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func passkeyAuthenticatorData(rp string, flags protocol.AuthenticatorFlags, count uint32) []byte {
	hash := sha256.Sum256([]byte(rp))
	data := make([]byte, 37, 128)
	copy(data, hash[:])
	data[32] = byte(flags)
	binary.BigEndian.PutUint32(data[33:37], count)
	return data
}

func passkeyRegistrationJSON(t *testing.T, key *ecdsa.PrivateKey, id []byte, rp, challenge, origin string) json.RawMessage {
	t.Helper()
	flags := protocol.FlagUserPresent | protocol.FlagUserVerified | protocol.FlagAttestedCredentialData
	authData := passkeyAuthenticatorData(rp, flags, 0)
	var aaguid [16]byte
	authData = append(authData, aaguid[:]...)
	authData = binary.BigEndian.AppendUint16(authData, uint16(len(id)))
	authData = append(authData, id...)
	keyData, err := webauthncbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1,
		-2: key.X.FillBytes(make([]byte, 32)), -3: key.Y.FillBytes(make([]byte, 32))})
	if err != nil {
		t.Fatal(err)
	}
	authData = append(authData, keyData...)
	attestation, err := webauthncbor.Marshal(map[string]any{"fmt": "none", "attStmt": map[string]any{}, "authData": authData})
	if err != nil {
		t.Fatal(err)
	}
	result, err := json.Marshal(map[string]any{"type": "public-key", "id": passkeyEncode(id), "rawId": passkeyEncode(id),
		"clientExtensionResults": map[string]any{"credProps": map[string]bool{"rk": true}},
		"response": map[string]string{"clientDataJSON": passkeyEncode(passkeyClientJSON(t, "webauthn.create", challenge, origin, false)),
			"attestationObject": passkeyEncode(attestation)}})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func passkeyAssertionJSON(t *testing.T, key *ecdsa.PrivateKey, id []byte, rp, challenge, origin string,
	handle []byte, flags protocol.AuthenticatorFlags, counter uint32, cross bool) json.RawMessage {
	t.Helper()
	client := passkeyClientJSON(t, "webauthn.get", challenge, origin, cross)
	clientHash := sha256.Sum256(client)
	authData := passkeyAuthenticatorData(rp, flags, counter)
	digest := sha256.Sum256(append(authData, clientHash[:]...))
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	result, err := json.Marshal(map[string]any{"type": "public-key", "id": passkeyEncode(id), "rawId": passkeyEncode(id),
		"clientExtensionResults": map[string]any{},
		"response": map[string]string{"clientDataJSON": passkeyEncode(client), "authenticatorData": passkeyEncode(authData),
			"userHandle": passkeyEncode(handle), "signature": passkeyEncode(signature)}})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestPasskeySignatureScopeFlagsAndCounters(t *testing.T) {
	const rp, web = "example.com", "https://example.com"
	android := "android:apk-key-hash:" + passkeyEncode(bytes.Repeat([]byte{1}, 32))
	engine := configuredPasskeys(rp, web+","+android)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, session, err := engine.web.BeginDiscoverableLogin()
	if err != nil {
		t.Fatal(err)
	}
	id, handle := []byte("fixture-credential-id"), passkeyUserHandle(42)
	stored := passkeyCredential{passkeyCredentialInfo: passkeyCredentialInfo{ID: passkeyEncode(id)}, owner: 42,
		x: passkeyEncode(key.X.FillBytes(make([]byte, 32))), y: passkeyEncode(key.Y.FillBytes(make([]byte, 32)))}
	goodFlags := protocol.FlagUserPresent | protocol.FlagUserVerified
	canonical := passkeyAssertionJSON(t, key, id, rp, session.Challenge, web, handle, goodFlags, 1, false)
	old := []byte(`"userHandle":"` + passkeyEncode(handle) + `"`)
	padded := bytes.Replace(canonical, old, []byte(`"userHandle":"`+passkeyEncode(handle)+`=="`), 1)
	if _, _, _, err := engine.assert(*session, padded); !errors.Is(err, errPasskeyProof) {
		t.Fatal("accepted a noncanonical user handle")
	}
	for _, tc := range []struct {
		name, rp, challenge, origin string
		idHandle                    []byte
		flags                       protocol.AuthenticatorFlags
		oldCount, count             uint32
		cross, good                 bool
		sign                        *ecdsa.PrivateKey
	}{
		{"normal", rp, session.Challenge, web, handle, goodFlags, 0, 1, false, true, key},
		{"zero counters", rp, session.Challenge, web, handle, goodFlags, 0, 0, false, true, key},
		{"Android", rp, session.Challenge, android, handle, goodFlags, 2, 3, false, true, key},
		{"bad RP", "other.example", session.Challenge, web, handle, goodFlags, 0, 1, false, false, key},
		{"bad challenge", rp, strings.Repeat("A", 43), web, handle, goodFlags, 0, 1, false, false, key},
		{"bad origin", rp, session.Challenge, web + "/bad", handle, goodFlags, 0, 1, false, false, key},
		{"cross-origin", rp, session.Challenge, web, handle, goodFlags, 0, 1, true, false, key},
		{"bad handle", rp, session.Challenge, web, passkeyUserHandle(43), goodFlags, 0, 1, false, false, key},
		{"missing UV", rp, session.Challenge, web, handle, protocol.FlagUserPresent, 0, 1, false, false, key},
		{"missing UP", rp, session.Challenge, web, handle, protocol.FlagUserVerified, 0, 1, false, false, key},
		{"backup changed", rp, session.Challenge, web, handle, goodFlags | protocol.FlagBackupEligible, 0, 1, false, false, key},
		{"stale count", rp, session.Challenge, web, handle, goodFlags, 2, 2, false, false, key},
		{"count reset", rp, session.Challenge, web, handle, goodFlags, 2, 0, false, false, key},
		{"bad signature", rp, session.Challenge, web, handle, goodFlags, 0, 1, false, false, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			signer := tc.sign
			if signer == nil {
				var err error
				signer, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
			}
			proof := passkeyAssertionJSON(t, signer, id, tc.rp, tc.challenge, tc.origin, tc.idHandle, tc.flags, tc.count, tc.cross)
			_, _, validate, err := engine.assert(*session, proof)
			credential := stored
			credential.count = tc.oldCount
			var use passkeyUse
			if err == nil {
				use, err = validate(credential)
			}
			if tc.good && (err != nil || use.count != tc.count) || !tc.good && !errors.Is(err, errPasskeyProof) {
				t.Fatalf("unexpected assertion result %+v, %v", use, err)
			}
		})
	}
}

type passkeyMemoryChallenge struct {
	key   passkeyChallengeKey
	state passkeyState
}

type passkeyHTTPFixture struct {
	*factorFixture
	sessions   *memorySessions
	challenges map[string]passkeyMemoryChallenge
	enrolled   map[string]passkeyCredential
}

func (f *passkeyHTTPFixture) Touch(ctx context.Context, claims auth.Claims) (int64, error) {
	return f.sessions.Touch(ctx, claims)
}

func (f *passkeyHTTPFixture) openPasskeys(context.Context) (passkeyPersistence, func(), error) {
	return f, func() {}, nil
}

func (f *passkeyHTTPFixture) owner(context.Context, int64) (passkeyOwner, error) {
	return passkeyOwner{LoginAccount: f.account}, nil
}

func (f *passkeyHTTPFixture) list(_ context.Context, owner int64) ([]passkeyCredentialInfo, error) {
	items := []passkeyCredentialInfo{}
	for _, credential := range f.enrolled {
		if credential.owner == owner {
			items = append(items, credential.passkeyCredentialInfo)
		}
	}
	return items, nil
}

func (f *passkeyHTTPFixture) storeChallenge(_ context.Context, key passkeyChallengeKey, state passkeyState) error {
	f.challenges[key.id] = passkeyMemoryChallenge{key, state}
	return nil
}

func (f *passkeyHTTPFixture) consumeChallenge(_ context.Context, key passkeyChallengeKey) (passkeyState, error) {
	c, ok := f.challenges[key.id]
	if !ok || c.key.purpose != key.purpose || c.key.owner.UserID != key.owner.UserID || c.key.owner.SessionID != key.owner.SessionID {
		return passkeyState{}, errPasskeyProof
	}
	delete(f.challenges, key.id)
	return c.state, nil
}

func (f *passkeyHTTPFixture) storeCredential(_ context.Context, claims auth.Claims, c passkeyCredential) (passkeyCredentialInfo, error) {
	if c.owner != claims.UserID {
		return passkeyCredentialInfo{}, errPasskeyProof
	}
	if _, exists := f.enrolled[c.ID]; exists {
		return passkeyCredentialInfo{}, errPasskeyConflict
	}
	f.enrolled[c.ID] = c
	return c.passkeyCredentialInfo, nil
}

func (f *passkeyHTTPFixture) useCredential(_ context.Context, owner int64, id string, verify func(passkeyCredential) (passkeyUse, error)) (LoginAccount, error) {
	c, ok := f.enrolled[id]
	if !ok || owner != c.owner {
		return LoginAccount{}, errPasskeyProof
	}
	update, err := verify(c)
	if err != nil {
		return LoginAccount{}, err
	}
	if !f.account.Active {
		return LoginAccount{}, errPasskeyOwner
	}
	c.count, c.back = update.count, update.back
	f.enrolled[id] = c
	return f.account, nil
}

func (f *passkeyHTTPFixture) remove(_ context.Context, owner int64, id string) error {
	c, ok := f.enrolled[id]
	if !ok || c.owner != owner {
		return errPasskeyMissing
	}
	delete(f.enrolled, id)
	return nil
}

func TestPasskeyHTTPRegistrationManagementAndExistingLoginLifecycle(t *testing.T) {
	const rp, origin = "example.com", "https://example.com"
	const prefix = "/api/v2/auth/passkeys/"
	codec, tokens := fixture(t)
	base, _, _ := newLoginFixture(t)
	f := &passkeyHTTPFixture{factorFixture: &factorFixture{loginFixtureStore: base},
		sessions: store(), challenges: make(map[string]passkeyMemoryChallenge), enrolled: make(map[string]passkeyCredential)}
	cfg := RefreshConfig{passkeys: configuredPasskeys(rp, origin), clock: func() time.Time { return time.Unix(1700000000, 0) }}
	h := NewHandlerWithConfig(codec, f, CorsPolicy{}, cfg)
	var trustedCookie string
	send := func(method, path, token string, body []byte, status int) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if trustedCookie != "" {
			req.AddCookie(&http.Cookie{Name: trustedDeviceCookie, Value: trustedCookie})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != status || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s returned %d: %s", path, w.Code, w.Body)
		}
		return w
	}
	request := func(route, token string) (id, challenge string) {
		t.Helper()
		w := send(http.MethodPost, prefix+route+"/options", token, nil, 200)
		var response struct {
			Data struct {
				ID      string `json:"challenge_id"`
				Options struct {
					Challenge string `json:"challenge"`
				} `json:"options"`
			} `json:"data"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if route == "registration" && (!strings.Contains(w.Body.String(), `"residentKey":"required"`) ||
			!strings.Contains(w.Body.String(), `"alg":-7`) || !strings.Contains(w.Body.String(), `"id":"AAAAAAAAAAAAAAAAAAAAKg"`)) {
			t.Fatalf("invalid registration options %s", w.Body)
		}
		if route == "authentication" && strings.Contains(w.Body.String(), `"allowCredentials"`) {
			t.Fatalf("non-discoverable authentication options %s", w.Body)
		}
		return response.Data.ID, response.Data.Options.Challenge
	}
	body := func(id string, proof json.RawMessage) []byte {
		t.Helper()
		encoded, err := json.Marshal(map[string]any{"challenge_id": id, "credential": proof})
		if err != nil {
			t.Fatal(err)
		}
		return encoded
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	token := tokens["access-hs256"]
	other, err := codec.Sign(auth.Claims{UserID: 42, UserName: "tester", SessionID: "peer", JTI: "peer-jti", Kind: auth.Access}, 900)
	if err != nil {
		t.Fatal(err)
	}
	id := []byte("route-fixture-key")
	challengeID, challenge := request("registration", token)
	reg := body(challengeID, passkeyRegistrationJSON(t, key, id, rp, challenge, origin))
	send(http.MethodPost, prefix+"registration/verification", other, reg, 401)
	w := send(http.MethodPost, prefix+"registration/verification", token, reg, 200)
	if !strings.Contains(w.Body.String(), `"label":"Passkey"`) || strings.Contains(w.Body.String(), "public_x") {
		t.Fatalf("incorrect public credential receipt %s", w.Body)
	}
	send(http.MethodPost, prefix+"registration/verification", token, reg, 401)
	send(http.MethodGet, "/api/v2/users/me/passkeys", token, nil, 200)
	challengeID, challenge = request("authentication", "")
	flags := protocol.FlagUserPresent | protocol.FlagUserVerified
	bad := passkeyAssertionJSON(t, key, id, rp, challenge, "https://other.example.com", passkeyUserHandle(42), flags, 1, false)
	send(http.MethodPost, prefix+"authentication/verification", "", body(challengeID, bad), 401)
	good := passkeyAssertionJSON(t, key, id, rp, challenge, origin, passkeyUserHandle(42), flags, 1, false)
	send(http.MethodPost, prefix+"authentication/verification", "", body(challengeID, good), 401)

	challengeID, challenge = request("authentication", "")
	good = passkeyAssertionJSON(t, key, id, rp, challenge, origin, passkeyUserHandle(42), flags, 1, false)
	result := send(http.MethodPost, prefix+"authentication/verification", "", body(challengeID, good), 200)
	if len(result.Result().Cookies()) != 2 || len(f.inserted) != 1 || f.alertCount != 1 || f.enrolled[passkeyEncode(id)].count != 1 {
		t.Fatal("valid passkey did not follow the existing login session and alert lifecycle")
	}
	f.account.Active = false
	challengeID, challenge = request("authentication", "")
	good = passkeyAssertionJSON(t, key, id, rp, challenge, origin, passkeyUserHandle(42), flags, 2, false)
	result = send(http.MethodPost, prefix+"authentication/verification", "", body(challengeID, good), 403)
	if len(result.Result().Cookies()) != 0 || len(f.inserted) != 1 || f.enrolled[passkeyEncode(id)].count != 1 {
		t.Fatal("verified proof issued a session for an inactive account")
	}
	f.account.Active = true
	f.twoFactor = true
	challengeID, challenge = request("authentication", "")
	good = passkeyAssertionJSON(t, key, id, rp, challenge, origin, passkeyUserHandle(42), flags, 2, false)
	encoded, err := json.Marshal(map[string]any{"challenge_id": challengeID, "credential": good, "remember_me": true})
	if err != nil {
		t.Fatal(err)
	}
	result = send(http.MethodPost, prefix+"authentication/verification", "", encoded, 200)
	if !f.challenge.Remember || f.challenge.ID == "" || !strings.Contains(result.Body.String(), `"two_factor_required":true`) ||
		len(result.Result().Cookies()) != 0 || len(f.inserted) != 1 {
		t.Fatal("Passkey login bypassed the existing two-factor challenge")
	}
	trustedCookie = "td1_" + strings.Repeat("a", 64)
	f.trusted, f.trustedKey = true, "td1_"+refreshHash(trustedCookie)
	challengeID, challenge = request("authentication", "")
	good = passkeyAssertionJSON(t, key, id, rp, challenge, origin, passkeyUserHandle(42), flags, 3, false)
	result = send(http.MethodPost, prefix+"authentication/verification", "", body(challengeID, good), 200)
	if len(result.Result().Cookies()) != 2 || len(f.inserted) != 2 || f.inserted[1].trustedDeviceKey != f.trustedKey {
		t.Fatal("Passkey login did not preserve the existing trusted-device claim")
	}
	send(http.MethodDelete, "/api/v2/users/me/passkeys/"+passkeyEncode(id), token, nil, 200)
	send(http.MethodDelete, "/api/v2/users/me/passkeys/"+passkeyEncode(id), token, nil, 404)
}
