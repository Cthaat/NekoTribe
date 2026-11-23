package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type passkeyChallengeKey struct {
	id, purpose string
	owner       auth.Claims
}

func (key passkeyChallengeKey) binds() []any {
	var owner, session any
	if key.purpose == passkeyRegister {
		owner, session = key.owner.UserID, key.owner.SessionID
	}
	return []any{
		sql.Named("challenge_id", key.id), sql.Named("purpose", key.purpose), sql.Named("issuer", passkeyIssuer),
		sql.Named("owner_user_id", owner), sql.Named("owner_session_id", session),
	}
}

type passkeyState struct{ challenge, data string }

type passkeyPersistence interface {
	owner(context.Context, int64) (passkeyOwner, error)
	list(context.Context, int64) ([]passkeyCredentialInfo, error)
	storeChallenge(context.Context, passkeyChallengeKey, passkeyState) error
	consumeChallenge(context.Context, passkeyChallengeKey) (passkeyState, error)
	storeCredential(context.Context, auth.Claims, passkeyCredential) (passkeyCredentialInfo, error)
	useCredential(context.Context, int64, string, func(passkeyCredential) (passkeyUse, error)) (LoginAccount, error)
	remove(context.Context, int64, string) error
}

type passkeyStore interface {
	openPasskeys(context.Context) (passkeyPersistence, func(), error)
}

type oraclePasskeys struct{ conn *sql.Conn }

func (s OracleSessions) openPasskeys(ctx context.Context) (passkeyPersistence, func(), error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, nil, errSessionStore
	}
	closeConn := func() { _ = conn.Close() }
	var catalog schemaCatalog
	if json.Unmarshal(contracts.PasskeyAuthSchemaCatalog, &catalog) != nil ||
		validateFeatureSchema(ctx, conn, catalog, "passkey-auth") != nil {
		closeConn()
		return nil, nil, errPasskeyUnavailable
	}
	return oraclePasskeys{conn}, closeConn, nil
}

type authTxStarter interface {
	BeginTx(context.Context, *sql.TxOptions) (*sql.Tx, error)
}

func authTransaction[T any](ctx context.Context, conn authTxStarter, work func(*sql.Tx) (T, error)) (T, error) {
	var zero T
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return zero, errSessionStore
	}
	defer tx.Rollback()
	value, err := work(tx)
	if err != nil {
		if rollbackErr := tx.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) {
			return zero, errSessionStore
		}
		return zero, err
	}
	if err := tx.Commit(); err != nil {
		return zero, errSessionStore
	}
	return value, nil
}

func readPasskeyOwner(ctx context.Context, db publicProfileQueryer, id int64) (passkeyOwner, error) {
	var owner passkeyOwner
	var password, display sql.NullString
	var active int
	err := db.QueryRowContext(ctx, passkeyAuth.SQL["owner"], sql.Named("user_id", id)).
		Scan(&owner.UserID, &owner.Username, &display, &password, &active, &owner.Status)
	if errors.Is(err, sql.ErrNoRows) {
		return owner, errPasskeyOwner
	}
	if err != nil || owner.UserID != id {
		return owner, errSessionStore
	}
	owner.PasswordHash, owner.display, owner.Active = password.String, display.String, active == 1
	return owner, nil
}

func (s oraclePasskeys) owner(ctx context.Context, id int64) (passkeyOwner, error) {
	user, err := readPasskeyOwner(ctx, s.conn, id)
	if err == nil && (!user.Active || user.Status != "active") {
		err = errPasskeyOwner
	}
	return user, err
}

func readPasskeyList(ctx context.Context, db schemaQueryer, owner int64) ([]passkeyCredentialInfo, error) {
	rows, err := db.QueryContext(ctx, passkeyAuth.SQL["credentialList"], sql.Named("user_id", owner))
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	items := []passkeyCredentialInfo{}
	for rows.Next() {
		var item passkeyCredentialInfo
		var created, used sql.NullTime
		if err := rows.Scan(&item.ID, &item.Label, &created, &used); err != nil || !created.Valid {
			return nil, errSessionStore
		}
		item.Created, item.LastUsed = *profileDate(created), profileDate(used)
		items = append(items, item)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, errSessionStore
	}
	return items, nil
}

func (s oraclePasskeys) list(ctx context.Context, owner int64) ([]passkeyCredentialInfo, error) {
	return readPasskeyList(ctx, s.conn, owner)
}

func (s oraclePasskeys) storeChallenge(ctx context.Context, key passkeyChallengeKey, state passkeyState) error {
	_, err := authTransaction(ctx, s.conn, func(tx *sql.Tx) (struct{}, error) {
		var zero struct{}
		if _, err := tx.ExecContext(ctx, passkeyAuth.SQL["challengePrune"]); err != nil {
			return zero, errSessionStore
		}
		binds := append(key.binds(), sql.Named("challenge", state.challenge), sql.Named("engine_state", state.data),
			sql.Named("ttl_seconds", passkeyAuth.TTLSeconds))
		return zero, writeOneChatRow(ctx, tx, passkeyAuth.SQL["challengeInsert"], binds...)
	})
	return err
}

func (s oraclePasskeys) consumeChallenge(ctx context.Context, key passkeyChallengeKey) (passkeyState, error) {
	return authTransaction(ctx, s.conn, func(tx *sql.Tx) (passkeyState, error) {
		var state passkeyState
		var engine sql.NullString
		err := tx.QueryRowContext(ctx, passkeyAuth.SQL["challengeLock"], key.binds()...).Scan(&state.challenge, &engine)
		if errors.Is(err, sql.ErrNoRows) {
			return state, errPasskeyProof
		}
		if err != nil {
			return state, errSessionStore
		}
		state.data = engine.String
		err = writeOneChatRow(ctx, tx, passkeyAuth.SQL["challengeDelete"], sql.Named("challenge_id", key.id))
		return state, err
	})
}

func lockActiveAuthOwner(ctx context.Context, tx *sql.Tx, id int64) (string, error) {
	var hash sql.NullString
	var found int64
	err := tx.QueryRowContext(ctx, passkeyAuth.SQL["lockOwner"], sql.Named("user_id", id)).Scan(&found, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", errPasskeyOwner
	}
	if err != nil || id != found {
		return "", errSessionStore
	}
	return hash.String, nil
}

func lockPasskeyCredential(ctx context.Context, tx *sql.Tx, id string) (passkeyCredential, error) {
	var c passkeyCredential
	var created, used sql.NullTime
	var eligible, back int64
	err := tx.QueryRowContext(ctx, passkeyAuth.SQL["credentialRead"], sql.Named("credential_id", id)).
		Scan(&c.ID, &c.owner, &c.x, &c.y, &c.count, &eligible, &back, &c.Label, &created, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return c, errPasskeyProof
	}
	if err != nil || c.ID != id || !created.Valid {
		return c, errSessionStore
	}
	c.eligible, c.back = eligible == 1, back == 1
	c.Created, c.LastUsed = *profileDate(created), profileDate(used)
	return c, nil
}

func passkeyFlag(value bool) int {
	if value {
		return 1
	}
	return 0
}

func (s oraclePasskeys) storeCredential(ctx context.Context, claims auth.Claims, c passkeyCredential) (passkeyCredentialInfo, error) {
	return authTransaction(ctx, s.conn, func(tx *sql.Tx) (passkeyCredentialInfo, error) {
		var zero passkeyCredentialInfo
		if _, err := lockActiveAuthOwner(ctx, tx, claims.UserID); err != nil {
			return zero, err
		}
		user := sql.Named("user_id", claims.UserID)
		touched, err := postTxExecute(ctx, tx, TouchSQL, user, sql.Named("session_id", claims.SessionID), sql.Named("access_jti", claims.JTI))
		if err != nil || touched > 1 {
			return zero, errSessionStore
		}
		if touched == 0 || c.owner != claims.UserID {
			return zero, errPasskeyProof
		}
		result, err := tx.ExecContext(ctx, passkeyAuth.SQL["credentialInsert"], sql.Named("credential_id", c.ID), user,
			sql.Named("public_x", c.x), sql.Named("public_y", c.y), sql.Named("sign_count", int64(c.count)),
			sql.Named("backup_eligible", passkeyFlag(c.eligible)), sql.Named("backed_up", passkeyFlag(c.back)), sql.Named("label", c.Label))
		if oracleErrorCode(err, "ORA-00001") {
			return zero, errPasskeyConflict
		}
		if err != nil {
			return zero, errSessionStore
		}
		if affected, err := result.RowsAffected(); err != nil || affected != 1 {
			return zero, errSessionStore
		}
		stored, err := lockPasskeyCredential(ctx, tx, c.ID)
		if err != nil {
			return zero, errSessionStore
		}
		return stored.passkeyCredentialInfo, nil
	})
}

func (s oraclePasskeys) useCredential(ctx context.Context, owner int64, id string, verify func(passkeyCredential) (passkeyUse, error)) (LoginAccount, error) {
	return authTransaction(ctx, s.conn, func(tx *sql.Tx) (LoginAccount, error) {
		user := sql.Named("user_id", owner)
		var locked int64
		err := tx.QueryRowContext(ctx, lockLoginUserSQL, user).Scan(&locked)
		if errors.Is(err, sql.ErrNoRows) {
			return LoginAccount{}, errPasskeyProof
		}
		if err != nil || locked != owner {
			return LoginAccount{}, errSessionStore
		}
		credential, err := lockPasskeyCredential(ctx, tx, id)
		if err != nil {
			return LoginAccount{}, err
		}
		if credential.owner != owner {
			return LoginAccount{}, errPasskeyProof
		}
		used, err := verify(credential)
		if err != nil {
			return LoginAccount{}, err
		}
		account, err := readVerifiedAuthAccount(ctx, tx, owner)
		if err != nil {
			return LoginAccount{}, err
		}
		err = writeOneChatRow(ctx, tx, passkeyAuth.SQL["credentialUse"], user, sql.Named("credential_id", id),
			sql.Named("sign_count", int64(used.count)), sql.Named("backed_up", passkeyFlag(used.back)))
		return account, err
	})
}

func readVerifiedAuthAccount(ctx context.Context, tx *sql.Tx, owner int64) (LoginAccount, error) {
	account, err := readPasskeyOwner(ctx, tx, owner)
	if err != nil {
		return LoginAccount{}, err
	}
	if !account.Active && account.Status == "suspended" {
		if err := restoreExpiredBanLocked(ctx, tx, sql.Named("user_id", owner)); err != nil {
			return LoginAccount{}, err
		}
		account, err = readPasskeyOwner(ctx, tx, owner)
		if err != nil {
			return LoginAccount{}, err
		}
	}
	if !account.Active || account.Status != "active" {
		return LoginAccount{}, errPasskeyOwner
	}
	return account.LoginAccount, nil
}

func (s oraclePasskeys) remove(ctx context.Context, owner int64, id string) error {
	_, err := authTransaction(ctx, s.conn, func(tx *sql.Tx) (struct{}, error) {
		var zero struct{}
		hash, err := lockActiveAuthOwner(ctx, tx, owner)
		if err != nil {
			return zero, err
		}
		items, err := readPasskeyList(ctx, tx, owner)
		if err != nil {
			return zero, err
		}
		if !slices.ContainsFunc(items, func(item passkeyCredentialInfo) bool { return item.ID == id }) {
			return zero, errPasskeyMissing
		}
		if len(items) == 1 && !passkeyPasswordHash.MatchString(hash) {
			link, err := readGitHubLinkForUser(ctx, tx, owner, true)
			if err != nil {
				return zero, err
			}
			if link == nil {
				return zero, errPasskeyLast
			}
		}
		err = writeOneChatRow(ctx, tx, passkeyAuth.SQL["credentialDelete"], sql.Named("credential_id", id), sql.Named("user_id", owner))
		return zero, err
	})
	return err
}
