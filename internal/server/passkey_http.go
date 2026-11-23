package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/protocol/webauthncose"
	"github.com/go-webauthn/webauthn/webauthn"
)

type passkeyOperation struct {
	action, purpose, id string
}

func passkeyPath(method, path string) (passkeyOperation, bool) {
	if method == http.MethodPost {
		switch path {
		case "/api/v2/auth/passkeys/registration/options":
			return passkeyOperation{action: "options", purpose: passkeyRegister}, true
		case "/api/v2/auth/passkeys/registration/verification":
			return passkeyOperation{action: "verify", purpose: passkeyRegister}, true
		case "/api/v2/auth/passkeys/authentication/options":
			return passkeyOperation{action: "options", purpose: passkeyLogin}, true
		case "/api/v2/auth/passkeys/authentication/verification":
			return passkeyOperation{action: "verify", purpose: passkeyLogin}, true
		}
	}
	if path == "/api/v2/users/me/passkeys" && method == http.MethodGet {
		return passkeyOperation{action: "list"}, true
	}
	id, ok := strings.CutPrefix(path, "/api/v2/users/me/passkeys/")
	if method == http.MethodDelete && ok && !strings.Contains(id, "/") {
		return passkeyOperation{action: "delete", id: id}, true
	}
	return passkeyOperation{}, false
}

func passkeySession(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository) (auth.Claims, bool) {
	var zero auth.Claims
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return zero, false
	}
	claims, err := codec.Verify(token, auth.Access)
	if err == nil {
		count, e := repo.Touch(r.Context(), claims)
		if e == nil && count == 1 {
			return claims, true
		}
	}
	respond(w, 401, 40101, "Token无效或已过期", nil)
	return zero, false
}

type passkeyProofBody struct {
	id, label string
	proof     json.RawMessage
	remember  bool
}

func readPasskeyProof(r *http.Request, purpose string) (passkeyProofBody, error) {
	var proof passkeyProofBody
	data, err := io.ReadAll(io.LimitReader(r.Body, int64(passkeyAuth.MaxPayloadBytes)+1))
	if err != nil || len(data) > passkeyAuth.MaxPayloadBytes {
		return proof, errPasskeyInvalid
	}
	var body map[string]json.RawMessage
	if json.Unmarshal(data, &body) != nil || json.Unmarshal(body["challenge_id"], &proof.id) != nil {
		return proof, errPasskeyInvalid
	}
	if _, ok := passkeyDecode(proof.id, passkeyAuth.ChallengeIDBytes, passkeyAuth.ChallengeIDBytes); !ok {
		return proof, errPasskeyInvalid
	}
	proof.proof = bytes.TrimSpace(body["credential"])
	var envelope struct {
		ID       string          `json:"id"`
		RawID    string          `json:"rawId"`
		Type     string          `json:"type"`
		Response json.RawMessage `json:"response"`
	}
	if json.Unmarshal(proof.proof, &envelope) != nil || envelope.ID != envelope.RawID ||
		envelope.Type != string(protocol.PublicKeyCredentialType) {
		return proof, errPasskeyInvalid
	}
	response := bytes.TrimSpace(envelope.Response)
	if _, valid := passkeyDecode(envelope.ID, 1, passkeyAuth.MaxCredentialIDBytes); !valid ||
		len(response) == 0 || response[0] != '{' {
		return proof, errPasskeyInvalid
	}
	for key := range body {
		if key != "challenge_id" && key != "credential" &&
			!(purpose == passkeyRegister && key == "label") && !(purpose == passkeyLogin && key == "remember_me") {
			return proof, errPasskeyInvalid
		}
	}
	if purpose == passkeyRegister {
		proof.label, err = parsePasskeyLabel(body["label"])
		return proof, err
	}
	if raw, has := body["remember_me"]; has {
		var remember *bool
		if json.Unmarshal(raw, &remember) != nil || remember == nil {
			return proof, errPasskeyInvalid
		}
		proof.remember = *remember
	}
	return proof, nil
}

type passkeyOptions struct {
	ID      string `json:"challenge_id"`
	Options any    `json:"options"`
}

func beginPasskey(ctx context.Context, store passkeyPersistence, engine *passkeyEngine, key passkeyChallengeKey) (passkeyOptions, error) {
	var data passkeyOptions
	var state *webauthn.SessionData
	if key.purpose == passkeyRegister {
		owner, err := store.owner(ctx, key.owner.UserID)
		if err != nil {
			return data, err
		}
		registered, err := store.list(ctx, key.owner.UserID)
		if err != nil {
			return data, err
		}
		excluded := make([]protocol.CredentialDescriptor, 0, len(registered))
		for _, existing := range registered {
			id, ok := passkeyDecode(existing.ID, 1, passkeyAuth.MaxCredentialIDBytes)
			if !ok {
				return data, errSessionStore
			}
			excluded = append(excluded, protocol.CredentialDescriptor{Type: protocol.PublicKeyCredentialType, CredentialID: id})
		}
		options, pending, err := engine.web.BeginRegistration(owner,
			webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired), webauthn.WithExclusions(excluded),
			webauthn.WithExtensions(webauthn.WithExtensionCredProps()),
			webauthn.WithCredentialParameters([]protocol.CredentialParameter{
				{Type: protocol.PublicKeyCredentialType, Algorithm: webauthncose.COSEAlgorithmIdentifier(passkeyAuth.Algorithm)},
			}))
		if err != nil {
			return data, errSessionStore
		}
		state, data.Options = pending, options.Response
	} else {
		options, pending, err := engine.web.BeginDiscoverableLogin(webauthn.WithUserVerification(protocol.VerificationRequired))
		if err != nil {
			return data, errSessionStore
		}
		state, data.Options = pending, options.Response
	}
	engineState, err := json.Marshal(state)
	if err != nil || len(engineState) > 4000 {
		return passkeyOptions{}, errSessionStore
	}
	key.id, err = newPasskeyID()
	if err != nil {
		return passkeyOptions{}, err
	}
	data.ID = key.id
	if err := store.storeChallenge(ctx, key, passkeyState{state.Challenge, string(engineState)}); err != nil {
		return passkeyOptions{}, err
	}
	return data, nil
}

func passkeyError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errPasskeyInvalid):
		respond(w, 400, 40001, "Passkey 参数错误", nil)
	case errors.Is(err, errPasskeyProof):
		respond(w, 401, 40101, passkeyStale, nil)
	case errors.Is(err, errPasskeyOwner):
		respond(w, 403, 40301, "账号不可用", nil)
	case errors.Is(err, errPasskeyMissing):
		respond(w, 404, 40401, "Passkey 不存在", nil)
	case errors.Is(err, errPasskeyConflict):
		respond(w, 409, 40901, "Passkey 已登记", nil)
	case errors.Is(err, errPasskeyLast):
		respond(w, 409, 40901, "必须保留至少一种登录方式", nil)
	case errors.Is(err, errPasskeyUnavailable):
		respond(w, 503, 50301, "Passkey 暂不可用", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
}

func passkeyRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	op, ok := passkeyPath(r.Method, r.URL.EscapedPath())
	if !ok {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	var claims auth.Claims
	if op.purpose != passkeyLogin {
		claims, ok = passkeySession(w, r, codec, repository)
		if !ok {
			return true
		}
	}
	store, ok := repository.(passkeyStore)
	if config.passkeys == nil || !ok {
		passkeyError(w, errPasskeyUnavailable)
		return true
	}
	var body passkeyProofBody
	if op.action == "verify" {
		var err error
		body, err = readPasskeyProof(r, op.purpose)
		if err != nil {
			passkeyError(w, err)
			return true
		}
	}
	if op.action == "delete" {
		raw, err := url.PathUnescape(op.id)
		_, valid := passkeyDecode(raw, 1, passkeyAuth.MaxCredentialIDBytes)
		if err != nil || !valid {
			passkeyError(w, errPasskeyInvalid)
			return true
		}
		op.id = raw
	}
	ctx := r.Context()
	db, closeDB, err := store.openPasskeys(ctx)
	if err != nil {
		passkeyError(w, err)
		return true
	}
	defer closeDB()
	switch op.action {
	case "options":
		data, err := beginPasskey(ctx, db, config.passkeys, passkeyChallengeKey{purpose: op.purpose, owner: claims})
		if err != nil {
			passkeyError(w, err)
		} else {
			respond(w, 200, 200, "success", data)
		}
	case "list":
		items, err := db.list(ctx, claims.UserID)
		if err != nil {
			passkeyError(w, err)
		} else {
			respond(w, 200, 200, "success", struct {
				Credentials []passkeyCredentialInfo `json:"credentials"`
			}{items})
		}
	case "delete":
		if err := db.remove(ctx, claims.UserID, op.id); err != nil {
			passkeyError(w, err)
		} else {
			respond(w, 200, 200, "success", nil)
		}
	case "verify":
		verifyPasskey(w, r, codec, repository, db, closeDB, config, passkeyChallengeKey{
			id: body.id, purpose: op.purpose, owner: claims,
		}, body)
	}
	return true
}

func verifyPasskey(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository,
	db passkeyPersistence, closeDB func(), config RefreshConfig, key passkeyChallengeKey, body passkeyProofBody) {
	ctx := r.Context()
	state, err := db.consumeChallenge(ctx, key)
	if err != nil {
		passkeyError(w, err)
		return
	}
	session, err := config.passkeys.decodeState(state.challenge, state.data)
	if err != nil {
		passkeyError(w, err)
		return
	}
	if key.purpose == passkeyRegister {
		credential, err := config.passkeys.register(key.owner.UserID, session, body.proof, body.label)
		if err != nil {
			passkeyError(w, err)
			return
		}
		info, err := db.storeCredential(ctx, key.owner, credential)
		if err != nil {
			passkeyError(w, err)
			return
		}
		respond(w, 200, 200, "success", struct {
			Credential passkeyCredentialInfo `json:"credential"`
		}{info})
		return
	}
	owner, id, verify, err := config.passkeys.assert(session, body.proof)
	if err != nil {
		passkeyError(w, err)
		return
	}
	user, err := db.useCredential(ctx, owner, id, verify)
	if err != nil {
		passkeyError(w, err)
		return
	}
	closeDB()
	login, ok := repository.(LoginRepository)
	if !ok {
		passkeyError(w, errPasskeyUnavailable)
		return
	}
	finishPrimaryLogin(w, r, codec, login, user, user.Username, passkeyStale, body.remember, config, nil)
}
