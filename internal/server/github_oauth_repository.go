package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type githubFlowOwner struct {
	purpose string
	claims  auth.Claims
}

func (owner githubFlowOwner) binds() []any {
	var id, session any
	if owner.purpose == githubLinkPurpose {
		id, session = owner.claims.UserID, owner.claims.SessionID
	}
	return []any{sql.Named("purpose", owner.purpose), sql.Named("owner_user_id", id), sql.Named("owner_session_id", session)}
}

type githubCallbackClaim struct{ flowID, verifier string }

type githubOAuthLink struct {
	githubIdentity
	userID   int64
	LinkedAt string `json:"linked_at"`
}

type githubOAuthPersistence interface {
	begin(context.Context, githubFlowOwner, githubFlowSecrets) error
	claimCallback(context.Context, string) (githubCallbackClaim, error)
	finishCallback(context.Context, string, githubIdentity) error
	complete(context.Context, githubFlowOwner, string, string) (githubIdentity, bool, error)
	linkForUser(context.Context, int64) (*githubOAuthLink, error)
	link(context.Context, auth.Claims, githubIdentity) (*githubOAuthLink, error)
	unlink(context.Context, auth.Claims) error
	loginAccount(context.Context, githubIdentity) (LoginAccount, error)
}

type githubOAuthStore interface {
	openGitHubOAuth(context.Context) (githubOAuthPersistence, error)
}

type oracleGitHubOAuth struct{ db *sql.DB }

func (s OracleSessions) openGitHubOAuth(ctx context.Context) (githubOAuthPersistence, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errGitHubUnavailable
	}
	defer conn.Close()
	var catalog schemaCatalog
	if json.Unmarshal(contracts.GitHubOAuthSchemaCatalog, &catalog) != nil ||
		validateFeatureSchema(ctx, conn, catalog, "github-oauth") != nil {
		return nil, errGitHubUnavailable
	}
	return oracleGitHubOAuth{s.DB}, nil
}

func (s oracleGitHubOAuth) begin(ctx context.Context, owner githubFlowOwner, flow githubFlowSecrets) error {
	_, err := authTransaction(ctx, s.db, func(tx *sql.Tx) (struct{}, error) {
		var zero struct{}
		if _, err := tx.ExecContext(ctx, githubOAuth.SQL["prune"]); err != nil {
			return zero, errSessionStore
		}
		binds := append(owner.binds(), sql.Named("flow_id", flow.id), sql.Named("state_hash", refreshHash(flow.state)),
			sql.Named("flow_key_hash", refreshHash(flow.key)), sql.Named("pkce_verifier", flow.verifier),
			sql.Named("ttl_seconds", githubOAuth.TTLSeconds))
		return zero, writeOneChatRow(ctx, tx, githubOAuth.SQL["begin"], binds...)
	})
	return err
}

func (s oracleGitHubOAuth) claimCallback(ctx context.Context, state string) (githubCallbackClaim, error) {
	return authTransaction(ctx, s.db, func(tx *sql.Tx) (githubCallbackClaim, error) {
		var claim githubCallbackClaim
		var verifier sql.NullString
		err := tx.QueryRowContext(ctx, githubOAuth.SQL["callbackLock"], sql.Named("state_hash", refreshHash(state))).
			Scan(&claim.flowID, &verifier)
		if errors.Is(err, sql.ErrNoRows) {
			return claim, errGitHubUnverified
		}
		if err != nil || !validGitHubNonce(claim.flowID) {
			return claim, errSessionStore
		}
		claim.verifier = verifier.String
		affected, err := postTxExecute(ctx, tx, githubOAuth.SQL["callbackClaim"], sql.Named("flow_id", claim.flowID))
		if err != nil || affected > 1 {
			return claim, errSessionStore
		}
		if affected != 1 {
			return claim, errGitHubUnverified
		}
		return claim, nil
	})
}

func (s oracleGitHubOAuth) finishCallback(ctx context.Context, flowID string, id githubIdentity) error {
	status := "failed"
	var githubID, login any
	if id.ID != "" {
		status, githubID, login = "verified", id.ID, id.Login
	}
	_, err := authTransaction(ctx, s.db, func(tx *sql.Tx) (struct{}, error) {
		var zero struct{}
		affected, err := postTxExecute(ctx, tx, githubOAuth.SQL["callbackFinish"], sql.Named("flow_id", flowID),
			sql.Named("status", status), sql.Named("github_user_id", githubID), sql.Named("github_login", login))
		if err != nil || affected > 1 {
			return zero, errSessionStore
		}
		if affected != 1 {
			return zero, errGitHubUnverified
		}
		return zero, nil
	})
	return err
}

func (s oracleGitHubOAuth) complete(ctx context.Context, owner githubFlowOwner, flowID, key string) (githubIdentity, bool, error) {
	var id githubIdentity
	var status string
	_, err := authTransaction(ctx, s.db, func(tx *sql.Tx) (struct{}, error) {
		var zero struct{}
		var nullableID, login sql.NullString
		binds := append(owner.binds(), sql.Named("flow_id", flowID), sql.Named("flow_key_hash", refreshHash(key)))
		err := tx.QueryRowContext(ctx, githubOAuth.SQL["completeLock"], binds...).Scan(&status, &nullableID, &login)
		if errors.Is(err, sql.ErrNoRows) {
			return zero, errGitHubUnverified
		}
		if err != nil {
			return zero, errSessionStore
		}
		if status == "pending" || status == "checking" {
			return zero, nil
		}
		id = githubIdentity{nullableID.String, login.String}
		affected, err := postTxExecute(ctx, tx, githubOAuth.SQL["completeConsume"], sql.Named("flow_id", flowID))
		if err != nil || affected > 1 {
			return zero, errSessionStore
		}
		if affected != 1 {
			return zero, errGitHubUnverified
		}
		return zero, nil
	})
	if err != nil {
		return githubIdentity{}, false, err
	}
	if status == "pending" || status == "checking" {
		return githubIdentity{}, true, nil
	}
	if status != "verified" || !validGitHubIdentity(id) {
		return githubIdentity{}, false, errGitHubUnverified
	}
	return id, false, nil
}

func readGitHubLink(ctx context.Context, db publicProfileQueryer, statement string, param sql.NamedArg, missingTableOK bool) (*githubOAuthLink, error) {
	var link githubOAuthLink
	var linked sql.NullTime
	err := db.QueryRowContext(ctx, statement, param).Scan(&link.userID, &link.ID, &link.Login, &linked)
	if errors.Is(err, sql.ErrNoRows) || missingTableOK && oracleErrorCode(err, "ORA-00942") {
		return nil, nil
	}
	if err != nil || !linked.Valid || !validGitHubIdentity(link.githubIdentity) {
		return nil, errSessionStore
	}
	link.LinkedAt = *profileDate(linked)
	return &link, nil
}

func readGitHubLinkForUser(ctx context.Context, db publicProfileQueryer, userID int64, missingTableOK bool) (*githubOAuthLink, error) {
	return readGitHubLink(ctx, db, githubOAuth.SQL["linkForUser"], sql.Named("user_id", userID), missingTableOK)
}

func (s oracleGitHubOAuth) linkForUser(ctx context.Context, userID int64) (*githubOAuthLink, error) {
	return readGitHubLinkForUser(ctx, s.db, userID, false)
}

func (s oracleGitHubOAuth) link(ctx context.Context, claims auth.Claims, id githubIdentity) (*githubOAuthLink, error) {
	return authTransaction(ctx, s.db, func(tx *sql.Tx) (*githubOAuthLink, error) {
		if _, err := lockActiveAuthOwner(ctx, tx, claims.UserID); err != nil {
			return nil, err
		}
		if err := ensureGitHubSession(ctx, tx, claims); err != nil {
			return nil, err
		}
		existing, err := readGitHubLinkForUser(ctx, tx, claims.UserID, false)
		if err != nil {
			return nil, err
		}
		if existing != nil {
			if existing.ID != id.ID {
				return nil, errGitHubConflict
			}
			return existing, nil
		}
		result, err := tx.ExecContext(ctx, githubOAuth.SQL["linkCreate"], sql.Named("user_id", claims.UserID),
			sql.Named("github_user_id", id.ID), sql.Named("github_login", id.Login))
		if oracleErrorCode(err, "ORA-00001") {
			return nil, errGitHubConflict
		}
		if err != nil {
			return nil, errSessionStore
		}
		if count, err := result.RowsAffected(); err != nil || count != 1 {
			return nil, errSessionStore
		}
		link, err := readGitHubLinkForUser(ctx, tx, claims.UserID, false)
		if err != nil || link == nil || link.ID != id.ID {
			return nil, errSessionStore
		}
		return link, nil
	})
}

func ensureGitHubSession(ctx context.Context, tx *sql.Tx, claims auth.Claims) error {
	affected, err := postTxExecute(ctx, tx, TouchSQL, sql.Named("user_id", claims.UserID),
		sql.Named("session_id", claims.SessionID), sql.Named("access_jti", claims.JTI))
	if err != nil || affected > 1 {
		return errSessionStore
	}
	if affected != 1 {
		return errGitHubUnverified
	}
	return nil
}

func (s oracleGitHubOAuth) unlink(ctx context.Context, claims auth.Claims) error {
	_, err := authTransaction(ctx, s.db, func(tx *sql.Tx) (struct{}, error) {
		var zero struct{}
		hash, err := lockActiveAuthOwner(ctx, tx, claims.UserID)
		if err != nil {
			return zero, err
		}
		if err := ensureGitHubSession(ctx, tx, claims); err != nil {
			return zero, err
		}
		link, err := readGitHubLinkForUser(ctx, tx, claims.UserID, false)
		if err != nil {
			return zero, err
		}
		if link == nil {
			return zero, errGitHubMissing
		}
		user := sql.Named("user_id", claims.UserID)
		if !passkeyPasswordHash.MatchString(hash) {
			var count int64
			err := tx.QueryRowContext(ctx, githubOAuth.SQL["passkeyCount"], user).Scan(&count)
			if err != nil && !oracleErrorCode(err, "ORA-00942") {
				return zero, errSessionStore
			}
			if count < 1 {
				return zero, errPasskeyLast
			}
		}
		return zero, writeOneChatRow(ctx, tx, githubOAuth.SQL["linkRemove"], user)
	})
	return err
}

func (s oracleGitHubOAuth) loginAccount(ctx context.Context, identity githubIdentity) (LoginAccount, error) {
	return authTransaction(ctx, s.db, func(tx *sql.Tx) (LoginAccount, error) {
		var zero LoginAccount
		stmt, id := githubOAuth.SQL["linkForGitHub"], sql.Named("github_user_id", identity.ID)
		link, err := readGitHubLink(ctx, tx, stmt, id, false)
		if err != nil {
			return zero, err
		}
		if link == nil {
			return zero, errGitHubUnverified
		}
		user := sql.Named("user_id", link.userID)
		var locked int64
		err = tx.QueryRowContext(ctx, lockLoginUserSQL, user).Scan(&locked)
		if errors.Is(err, sql.ErrNoRows) {
			return zero, errPasskeyOwner
		}
		if err != nil || locked != link.userID {
			return zero, errSessionStore
		}
		current, err := readGitHubLink(ctx, tx, stmt, id, false)
		if err != nil {
			return zero, err
		}
		if current == nil || current.userID != locked {
			return zero, errGitHubUnverified
		}
		return readVerifiedAuthAccount(ctx, tx, locked)
	})
}
