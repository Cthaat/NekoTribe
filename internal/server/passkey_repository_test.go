package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"maps"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type passkeyOracleFixture struct {
	schemaFixtureConnector
	driverState
	keys       map[string]passkeyCredential
	challenge  passkeyMemoryChallenge
	hash       string
	githubLink *githubOAuthLink
	expired    bool
	validToken bool
}

type passkeyOracleFixtureConn struct {
	*testConn
	fixture                *passkeyOracleFixture
	keys                   map[string]passkeyCredential
	challenge              passkeyMemoryChallenge
	active, owner, session bool
	challengeLocked        bool
}

func (f *passkeyOracleFixture) Connect(context.Context) (driver.Conn, error) {
	return &passkeyOracleFixtureConn{testConn: &testConn{&f.driverState}, fixture: f}, nil
}

func (f *passkeyOracleFixtureConn) Begin() (driver.Tx, error) {
	f.keys, f.challenge = maps.Clone(f.fixture.keys), f.fixture.challenge
	f.active, f.owner, f.session, f.challengeLocked = true, false, false, false
	return f, nil
}

func (c *passkeyOracleFixtureConn) Commit() error {
	c.fixture.commits++
	c.fixture.keys, c.fixture.challenge = c.keys, c.challenge
	c.active = false
	return nil
}

func (c *passkeyOracleFixtureConn) Rollback() error {
	c.fixture.rollbacks++
	c.active = false
	return nil
}

var passkeyDateFixture = time.Date(2026, 11, 23, 8, 0, 0, 0, time.UTC)

func (c *passkeyOracleFixtureConn) QueryContext(ctx context.Context, stmt string, args []driver.NamedValue) (driver.Rows, error) {
	f := c.fixture
	bind := func(name string) driver.Value { return directFixtureBind(args, name) }
	one := func(values ...driver.Value) (driver.Rows, error) { return &alertRows{values: values}, nil }
	none := func() (driver.Rows, error) { return emptyRows{&f.driverState}, nil }
	switch stmt {
	case passkeyAuth.SQL["challengeLock"]:
		if !c.active {
			return nil, errors.New("challenge checked without a transaction")
		}
		key := c.challenge.key
		if key.id == "" || f.expired || bind("challenge_id") != key.id || bind("purpose") != key.purpose ||
			bind("issuer") != passkeyIssuer || bind("owner_user_id") != key.owner.UserID || bind("owner_session_id") != key.owner.SessionID {
			return none()
		}
		c.challengeLocked = true
		return one(c.challenge.state.challenge, c.challenge.state.data)
	case passkeyAuth.SQL["lockOwner"], lockLoginUserSQL:
		c.owner = c.active && bind("user_id") == int64(42)
		if !c.owner {
			return none()
		}
		if stmt == lockLoginUserSQL {
			return one(int64(42))
		}
		return one(int64(42), f.hash)
	case passkeyAuth.SQL["owner"]:
		return one(int64(42), "tester", "Test user", f.hash, int64(1), "active")
	case githubOAuth.SQL["linkForUser"]:
		if f.githubLink == nil {
			return nil, errors.New("ORA-00942: table does not exist")
		}
		if !c.owner || bind("user_id") != f.githubLink.userID {
			return nil, errors.New("GitHub fallback checked without matching owner lock")
		}
		return one(f.githubLink.userID, f.githubLink.ID, f.githubLink.Login, passkeyDateFixture)
	case passkeyAuth.SQL["credentialRead"]:
		if !c.owner {
			return nil, errors.New("credential locked before owner")
		}
		cred, ok := c.keys[bind("credential_id").(string)]
		if !ok {
			return none()
		}
		return one(cred.ID, cred.owner, cred.x, cred.y, int64(cred.count), int64(passkeyFlag(cred.eligible)),
			int64(passkeyFlag(cred.back)), cred.Label, passkeyDateFixture, nil)
	case passkeyAuth.SQL["credentialList"]:
		items := &schemaFixtureRows{columns: make([]string, 4)}
		keys := f.keys
		if c.active {
			keys = c.keys
		}
		for _, k := range keys {
			if bind("user_id") == k.owner {
				items.values = append(items.values, []driver.Value{k.ID, k.Label, passkeyDateFixture, nil})
			}
		}
		return items, nil
	default:
		return (&schemaFixtureConn{f.schemaFixtureConnector}).QueryContext(ctx, stmt, args)
	}
}

func (c *passkeyOracleFixtureConn) ExecContext(_ context.Context, stmt string, args []driver.NamedValue) (driver.Result, error) {
	if !c.active {
		return nil, errors.New("write without transaction")
	}
	bind := func(name string) driver.Value { return directFixtureBind(args, name) }
	switch stmt {
	case passkeyAuth.SQL["challengePrune"]:
		return driver.RowsAffected(0), nil
	case passkeyAuth.SQL["challengeInsert"]:
		if bind("issuer") != passkeyIssuer || bind("ttl_seconds") != int64(300) ||
			bind("owner_user_id") != int64(42) || bind("owner_session_id") != "session" {
			return nil, errors.New("incorrect challenge bind")
		}
		c.challenge = passkeyMemoryChallenge{
			passkeyChallengeKey{id: bind("challenge_id").(string), purpose: bind("purpose").(string), owner: auth.Claims{UserID: 42, SessionID: "session"}},
			passkeyState{challenge: bind("challenge").(string), data: bind("engine_state").(string)},
		}
	case passkeyAuth.SQL["challengeDelete"]:
		if !c.challengeLocked || bind("challenge_id") != c.challenge.key.id {
			return nil, errors.New("challenge deleted before lock")
		}
		c.challenge = passkeyMemoryChallenge{}
	case TouchSQL:
		if !c.owner || !c.fixture.validToken || bind("session_id") != "session" || bind("access_jti") != "access-jti" {
			return driver.RowsAffected(0), nil
		}
		c.session = true
	case passkeyAuth.SQL["credentialInsert"]:
		if !c.owner || !c.session || bind("user_id") != int64(42) {
			return nil, errors.New("unscoped registration")
		}
		id := bind("credential_id").(string)
		if _, duplicated := c.keys[id]; duplicated {
			return nil, errors.New("ORA-00001: unique test row")
		}
		c.keys[id] = passkeyCredential{
			passkeyCredentialInfo: passkeyCredentialInfo{ID: id, Label: bind("label").(string)},
			x:                     bind("public_x").(string), y: bind("public_y").(string), owner: 42,
		}
	case passkeyAuth.SQL["credentialUse"]:
		id := bind("credential_id").(string)
		credential, ok := c.keys[id]
		if !c.owner || !ok || bind("user_id") != credential.owner {
			return nil, errors.New("unscoped assertion update")
		}
		credential.count = uint32(bind("sign_count").(int64))
		c.keys[id] = credential
	case passkeyAuth.SQL["credentialDelete"]:
		id := bind("credential_id").(string)
		if credential, ok := c.keys[id]; !c.owner || !ok || bind("user_id") != credential.owner {
			return nil, errors.New("unscoped removal")
		}
		delete(c.keys, id)
	default:
		return nil, errors.New("unexpected database write")
	}
	return driver.RowsAffected(1), nil
}

func TestPasskeyOracleChallengeConsumptionAndOwnerSession(t *testing.T) {
	f := &passkeyOracleFixture{keys: make(map[string]passkeyCredential)}
	db := sql.OpenDB(f)
	defer db.Close()
	ctx := context.Background()
	conn, err := db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	repo := oraclePasskeys{conn}
	key := passkeyChallengeKey{id: "fixture-id", purpose: passkeyRegister, owner: auth.Claims{UserID: 42, SessionID: "session"}}
	state := passkeyState{challenge: "fixture-challenge", data: "issuer fixture"}
	if err := repo.storeChallenge(ctx, key, state); err != nil || f.commits != 1 {
		t.Fatalf("challenge storage not committed, err %v", err)
	}
	foreign := key
	foreign.owner.SessionID = "other-session"
	if _, err := repo.consumeChallenge(ctx, foreign); !errors.Is(err, errPasskeyProof) || f.commits != 1 {
		t.Fatalf("foreign session consumed registration challenge: %v", err)
	}
	f.expired = true
	if _, err := repo.consumeChallenge(ctx, key); !errors.Is(err, errPasskeyProof) || f.commits != 1 {
		t.Fatalf("expired challenge could be used: %v", err)
	}
	f.expired = false
	if got, err := repo.consumeChallenge(ctx, key); err != nil || got != state || f.commits != 2 || f.challenge.key.id != "" {
		t.Fatalf("challenge not consumed before proof: %v", err)
	}
	if _, err := repo.consumeChallenge(ctx, key); !errors.Is(err, errPasskeyProof) || f.commits != 2 {
		t.Fatalf("successful challenge was replayable: %v", err)
	}
}

func TestPasskeyOracleCredentialLifecycleUsesOwnerLock(t *testing.T) {
	f := &passkeyOracleFixture{keys: make(map[string]passkeyCredential)}
	db := sql.OpenDB(f)
	defer db.Close()
	ctx := context.Background()
	conn, err := db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	p := oraclePasskeys{conn}
	owner := auth.Claims{UserID: 42, SessionID: "session", JTI: "access-jti"}
	key := passkeyCredential{owner: 42, passkeyCredentialInfo: passkeyCredentialInfo{ID: "fixture-key", Label: "New passkey"},
		x: "fixture-x", y: "fixture-y"}
	if _, err := p.storeCredential(ctx, owner, key); !errors.Is(err, errPasskeyProof) || len(f.keys) != 0 {
		t.Fatalf("revoked registration session persisted a key: %v", err)
	}
	f.validToken = true
	if summary, err := p.storeCredential(ctx, owner, key); err != nil || summary.ID != key.ID || summary.Created == "" {
		t.Fatalf("store key returned %+v, %v", summary, err)
	}
	if _, err := p.storeCredential(ctx, owner, key); !errors.Is(err, errPasskeyConflict) {
		t.Fatalf("duplicate registration error %v", err)
	}
	if _, err := p.useCredential(ctx, 42, key.ID, func(passkeyCredential) (passkeyUse, error) {
		return passkeyUse{}, errPasskeyProof
	}); !errors.Is(err, errPasskeyProof) || f.keys[key.ID].count != 0 {
		t.Fatalf("invalid proof updated credential: %v", err)
	}
	if account, err := p.useCredential(ctx, 42, key.ID, func(stored passkeyCredential) (passkeyUse, error) {
		if stored.owner != 42 {
			t.Fatal("assertion loaded a foreign key")
		}
		return passkeyUse{count: 10}, nil
	}); err != nil || account.UserID != 42 || f.keys[key.ID].count != 10 {
		t.Fatalf("valid proof not committed: %v", err)
	}
	if err := p.remove(ctx, 42, "foreign"); !errors.Is(err, errPasskeyMissing) {
		t.Fatalf("unowned removal error %v", err)
	}
	if err := p.remove(ctx, 42, key.ID); !errors.Is(err, errPasskeyLast) || len(f.keys) != 1 {
		t.Fatalf("last login method removed: %v", err)
	}
	f.githubLink = &githubOAuthLink{githubIdentity: githubIdentity{"77", "octocat"}, userID: 42}
	if err := p.remove(ctx, 42, key.ID); err != nil || len(f.keys) != 0 {
		t.Fatalf("removal with GitHub fallback failed: %v", err)
	}
	f.githubLink = nil
	f.keys[key.ID] = key
	f.hash = "$2b$04$" + strings.Repeat("A", 53)
	if err := p.remove(ctx, 42, key.ID); err != nil || len(f.keys) != 0 {
		t.Fatalf("removal with remaining password failed: %v", err)
	}
}

func TestPasskeyAndDraftCatalogAcceptIndexesAndRejectMissingCopies(t *testing.T) {
	for _, feature := range []struct {
		name string
		data []byte
		keys []string
	}{
		{"passkey-auth", contracts.PasskeyAuthSchemaCatalog, []string{"IDX_WEBAUTHN_CRED_OWNER", "IDX_WEBAUTHN_CHALL_EXPIRY"}},
		{"post-drafts", contracts.PostDraftsSchemaCatalog, []string{"IDX_POST_DRAFT_OWNER", "IDX_POST_DRAFT_DUE"}},
	} {
		t.Run(feature.name, func(t *testing.T) {
			ctx := context.Background()
			f := &passkeyOracleFixture{schemaFixtureConnector: postFeatureSchemaFixture(t, feature.data)}
			db := sql.OpenDB(f)
			defer db.Close()
			repo := OracleSessions{db}
			check := func() error {
				if feature.name == "post-drafts" {
					conn, err := repo.postDraftConnection(ctx)
					if err == nil {
						_ = conn.Close()
					}
					return err
				}
				_, close, err := repo.openPasskeys(ctx)
				if err == nil {
					close()
				}
				return err
			}
			if err := check(); err != nil {
				t.Fatalf("ready schema rejected: %v", err)
			}
			indexes := f.snapshot["indexes"].(map[string]any)
			for _, index := range feature.keys {
				entry := indexes[index]
				delete(indexes, index)
				if err := check(); err == nil {
					t.Fatalf("missing index %s accepted", index)
				}
				indexes[index] = entry
			}
			if !slices.ContainsFunc(*f.calls, func(q string) bool { return strings.Contains(q, "FROM user_ind_columns") }) ||
				f.commits != 0 || f.rollbacks != 0 {
				t.Fatal("schema check did not stay read-only")
			}
		})
	}
}
