package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"slices"
	"testing"
)

type userProviderSQLFixture struct {
	driverState
	owner  int64
	record *userProviderRecord
	steps  []string
}

type userProviderConnector struct{ state *userProviderSQLFixture }
type userProviderConn struct {
	*testConn
	state *userProviderSQLFixture
}

func (c userProviderConnector) Connect(context.Context) (driver.Conn, error) {
	return &userProviderConn{testConn: &testConn{&c.state.driverState}, state: c.state}, nil
}
func (userProviderConnector) Driver() driver.Driver { return testDriver{} }

func (c *userProviderConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	s := c.state
	if len(args) != 1 || args[0].Name != "user_id" {
		return nil, errors.New("expected exact owner binding")
	}
	switch query {
	case userProviderContract.SQL["lock_user"]:
		s.steps = append(s.steps, "lock")
		if args[0].Value == s.owner {
			return &alertRows{values: []driver.Value{s.owner}}, nil
		}
	case userProviderContract.SQL["read"]:
		s.steps = append(s.steps, "read")
		if args[0].Value == s.owner && s.record != nil {
			r := s.record
			enabled := int64(0)
			if r.Enabled {
				enabled = 1
			}
			return &alertRows{values: []driver.Value{r.Preset, r.BaseURL, r.Model, r.SecretBox, enabled, r.Revision}}, nil
		}
	default:
		return nil, errors.New("unexpected provider query")
	}
	return emptyRows{&s.driverState}, nil
}

func (c *userProviderConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	s := c.state
	if query != userProviderContract.SQL["save"] {
		return nil, errors.New("unexpected provider write")
	}
	s.steps = append(s.steps, "save")
	bound := make(map[string]driver.Value, len(args))
	for _, arg := range args {
		bound[arg.Name] = arg.Value
	}
	if bound["user_id"] != s.owner || len(bound) != 7 {
		return nil, errors.New("unexpected provider write scope")
	}
	s.record = &userProviderRecord{
		Preset: bound["preset_id"].(string), BaseURL: bound["base_url"].(string), Model: bound["model_name"].(string),
		SecretBox: bound["secret_box"].(string), Enabled: bound["enabled"] == int64(1), Revision: bound["revision"].(int64),
	}
	return driver.RowsAffected(1), nil
}

func TestUserProviderOracleSaveLocksOwnerBeforeReadingAndIncrements(t *testing.T) {
	settings := testUserProviderSettings(t, "https://provider.example.test/v1")
	state := &userProviderSQLFixture{owner: 42}
	db := sql.OpenDB(userProviderConnector{state})
	defer db.Close()
	store := OracleSessions{db}
	verify := func(context.Context, *sql.Conn) error { state.steps = append(state.steps, "schema"); return nil }
	key := "synthetic-key"
	input := userProviderInput{Preset: "provided", Model: "model", Enabled: true, APIKey: &key}
	first, err := store.saveUserProviderOperation(context.Background(), 42, settings, input, verify)
	if err != nil || first.Revision != 1 || state.commits != 1 || first.SecretBox == key || !slices.Equal(state.steps, []string{"schema", "lock", "read", "save"}) {
		t.Fatal(err, state.commits, state.steps)
	}
	state.steps = nil
	input.APIKey = nil
	input.Model = "model-2"
	second, err := store.saveUserProviderOperation(context.Background(), 42, settings, input, verify)
	if err != nil || second.Revision != 2 || second.SecretBox != first.SecretBox || state.commits != 2 || !slices.Equal(state.steps, []string{"schema", "lock", "read", "save"}) {
		t.Fatal(err, state.commits, state.steps)
	}
	state.steps = nil
	if _, err := store.saveUserProviderOperation(context.Background(), 43, settings, input, verify); !errors.Is(err, errUserProviderUnavailable) || state.commits != 2 || !slices.Equal(state.steps, []string{"schema", "lock"}) {
		t.Fatal(err, state.commits, state.steps)
	}
}
