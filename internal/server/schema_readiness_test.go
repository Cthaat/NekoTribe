package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
)

func TestSchemaExpressionNormalization(t *testing.T) {
	for _, tc := range []struct {
		left, right string
		same        bool
	}{
		{" ( ( REMEMBER_ME IN (1, 0) ) ) ", "remember_me IN (0,1)", true},
		{" ( CURRENT_TIMESTAMP ) ", "current_timestamp", true},
		{"name = 'Mixed Case'", "NAME='Mixed Case'", true},
		{"name='Mixed Case'", "name='MIXED CASE'", false},
		{"x in (0,1)", "x in (0,2)", false},
		{"\ufeffcurrent_timestamp\u00a0", "CURRENT_TIMESTAMP", true},
		{"current_\u0085timestamp", "CURRENT_TIMESTAMP", false},
	} {
		if got := normalizeSchemaExpression(tc.left) == normalizeSchemaExpression(tc.right); got != tc.same {
			t.Fatalf("%q vs %q: %v", tc.left, tc.right, got)
		}
	}
}

func TestSchemaColumnMetadata(t *testing.T) {
	column := schemaColumn{Name: "USER_ID", Type: "NUMBER(10)", Nullable: false}
	valid := schemaRow{"DATA_TYPE": "NUMBER", "DATA_PRECISION": int64(10), "DATA_SCALE": nil, "NULLABLE": "N", "DATA_DEFAULT": nil}
	if !schemaColumnMatches(column, valid) {
		t.Fatal("valid NUMBER rejected")
	}
	decimal := schemaRow{"DATA_TYPE": "NUMBER", "DATA_PRECISION": "10.0", "DATA_SCALE": "0e0", "NULLABLE": "N", "DATA_DEFAULT": nil}
	if !schemaColumnMatches(column, decimal) {
		t.Fatal("Oracle decimal text rejected")
	}
	for _, tc := range []struct {
		key   string
		value any
	}{{"DATA_PRECISION", int64(9)}, {"DATA_SCALE", int64(2)}, {"NULLABLE", "Y"}, {"DATA_TYPE", "VARCHAR2"}} {
		bad := schemaRow{}
		for k, v := range valid {
			bad[k] = v
		}
		bad[tc.key] = tc.value
		if schemaColumnMatches(column, bad) {
			t.Fatalf("accepted invalid %s", tc.key)
		}
	}
	stamp := schemaColumn{Name: "CREATED_AT", Type: "TIMESTAMP", Nullable: false, Default: stringPtr("CURRENT_TIMESTAMP")}
	if !schemaColumnMatches(stamp, schemaRow{"DATA_TYPE": "TIMESTAMP(6)", "NULLABLE": "N", "DATA_DEFAULT": " ( current_timestamp ) "}) {
		t.Fatal("valid default rejected")
	}
}

func stringPtr(value string) *string { return &value }

type schemaFixtureConnector struct {
	snapshot map[string]any
	calls    *[]string
	connects *int
}
type schemaFixtureConn struct{ schemaFixtureConnector }
type schemaFixtureRows struct {
	columns []string
	values  [][]driver.Value
	index   int
}

func (c schemaFixtureConnector) Connect(context.Context) (driver.Conn, error) {
	*c.connects++
	return &schemaFixtureConn{c}, nil
}
func (schemaFixtureConnector) Driver() driver.Driver { return testDriver{} }
func (*schemaFixtureConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (*schemaFixtureConn) Close() error              { return nil }
func (*schemaFixtureConn) Begin() (driver.Tx, error) { return nil, errors.New("unexpected begin") }
func (r *schemaFixtureRows) Columns() []string       { return r.columns }
func (*schemaFixtureRows) Close() error              { return nil }
func (r *schemaFixtureRows) Next(dest []driver.Value) error {
	if r.index >= len(r.values) {
		return io.EOF
	}
	copy(dest, r.values[r.index])
	r.index++
	return nil
}

func (c *schemaFixtureConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	*c.calls = append(*c.calls, query)
	if !strings.HasPrefix(strings.ToUpper(strings.TrimSpace(query)), "SELECT ") {
		return nil, errors.New("unexpected mutation")
	}
	value := func(name string) string {
		for _, arg := range args {
			if arg.Name == name {
				return arg.Value.(string)
			}
		}
		return ""
	}
	rows := func(columns []string, objects []any) driver.Rows {
		result := &schemaFixtureRows{columns: columns}
		for _, object := range objects {
			row := object.(map[string]any)
			values := make([]driver.Value, len(columns))
			for i, column := range columns {
				switch v := row[column].(type) {
				case nil:
					values[i] = nil
				case string:
					values[i] = v
				case float64:
					values[i] = int64(v)
				default:
					panic("invalid fixture value")
				}
			}
			result.values = append(result.values, values)
		}
		return result
	}
	upper := strings.ToUpper(query)
	if fail, _ := c.snapshot["failOnQuery"].(string); fail != "" && strings.Contains(upper, fail) {
		return nil, errors.New("synthetic-private-database-secret")
	}
	tables := c.snapshot["tables"].(map[string]any)
	switch {
	case strings.HasPrefix(upper, "SELECT USER AS"):
		o := c.snapshot["owner"].(map[string]any)
		return rows([]string{"USER_NAME", "SCHEMA_NAME"}, []any{map[string]any{"USER_NAME": o["user"], "SCHEMA_NAME": o["schema"]}}), nil
	case strings.Contains(upper, "FROM USER_TABLES"):
		name := value("name")
		exists := tables[name] != nil && (name != "N_SCHEMA_MIGRATIONS" || c.snapshot["ledgerPresent"].(bool))
		objects := []any{}
		if exists {
			objects = append(objects, map[string]any{"NAME": name})
		}
		return rows([]string{"NAME"}, objects), nil
	case strings.Contains(upper, "FROM USER_TAB_COLUMNS"):
		table := tables[value("table_name")]
		objects := []any{}
		if table != nil {
			objects = table.(map[string]any)["columns"].([]any)
		}
		return rows([]string{"COLUMN_NAME", "DATA_TYPE", "DATA_PRECISION", "DATA_SCALE", "CHAR_LENGTH", "NULLABLE", "DATA_DEFAULT"}, objects), nil
	case strings.Contains(upper, "FROM USER_CONSTRAINTS C"):
		table := tables[value("table_name")]
		objects := []any{}
		if table != nil {
			objects = table.(map[string]any)["constraints"].([]any)
		}
		return rows([]string{"CONSTRAINT_NAME", "CONSTRAINT_TYPE", "SEARCH_CONDITION_VC", "DELETE_RULE", "STATUS", "VALIDATED", "REFERENCED_TABLE", "REFERENCED_OWNER"}, objects), nil
	case strings.Contains(upper, "FROM USER_CONS_COLUMNS C"):
		table := tables[value("table_name")]
		objects := []any{}
		if table != nil {
			for _, item := range table.(map[string]any)["constraints"].([]any) {
				entry := item.(map[string]any)
				own, _ := entry["columns"].([]any)
				refs, _ := entry["referencedColumns"].([]any)
				for i, column := range own {
					var ref any
					if i < len(refs) {
						ref = refs[i]
					}
					objects = append(objects, map[string]any{"CONSTRAINT_NAME": entry["CONSTRAINT_NAME"], "COLUMN_NAME": column, "POSITION": float64(i + 1), "REFERENCED_COLUMN": ref})
				}
			}
		}
		return rows([]string{"CONSTRAINT_NAME", "COLUMN_NAME", "POSITION", "REFERENCED_COLUMN"}, objects), nil
	case strings.Contains(upper, "FROM USER_SEQUENCES"):
		objects := []any{}
		if x := c.snapshot["sequences"].(map[string]any)[value("name")]; x != nil {
			objects = append(objects, x)
		}
		return rows([]string{"SEQUENCE_NAME", "INCREMENT_BY", "CYCLE_FLAG"}, objects), nil
	case strings.Contains(upper, "FROM USER_INDEXES"):
		objects := []any{}
		if x := c.snapshot["indexes"].(map[string]any)[value("name")]; x != nil {
			objects = append(objects, x)
		}
		return rows([]string{"INDEX_NAME", "TABLE_NAME", "UNIQUENESS", "STATUS"}, objects), nil
	case strings.Contains(upper, "FROM USER_IND_COLUMNS"):
		objects := []any{}
		if x := c.snapshot["indexes"].(map[string]any)[value("name")]; x != nil {
			objects = x.(map[string]any)["columns"].([]any)
		}
		return rows([]string{"COLUMN_NAME", "DESCEND"}, objects), nil
	case strings.Contains(upper, "FROM N_SCHEMA_MIGRATIONS"):
		return rows([]string{"STEP_ID", "CHECKSUM"}, c.snapshot["records"].([]any)), nil
	default:
		return nil, errors.New("unexpected fixture query")
	}
}

func applySchemaMutation(node any, path []any, op string, value any) any {
	if len(path) == 0 {
		return value
	}
	switch parent := node.(type) {
	case map[string]any:
		key := path[0].(string)
		if len(path) == 1 && op == "delete" {
			delete(parent, key)
		} else {
			parent[key] = applySchemaMutation(parent[key], path[1:], op, value)
		}
		return parent
	case []any:
		index := int(path[0].(float64))
		if len(path) == 1 && op == "delete" {
			return append(parent[:index], parent[index+1:]...)
		}
		parent[index] = applySchemaMutation(parent[index], path[1:], op, value)
		return parent
	default:
		panic("invalid mutation")
	}
}

func TestSharedTwoFactorReadinessScenarios(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/two-factor-readiness.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ID       string          `json:"id"`
		Baseline json.RawMessage `json:"baseline"`
		Cases    []struct {
			ID        string `json:"id"`
			Ready     bool   `json:"ready"`
			Mutations []struct {
				Op    string `json:"op"`
				Path  []any  `json:"path"`
				Value any    `json:"value"`
			} `json:"mutations"`
		} `json:"cases"`
	}
	if err = json.Unmarshal(data, &fixture); err != nil || fixture.ID != "AUTH-2FA-READINESS" || len(fixture.Cases) != 30 {
		t.Fatal("invalid fixture", err)
	}
	for _, scenario := range fixture.Cases {
		t.Run(scenario.ID, func(t *testing.T) {
			var snapshot map[string]any
			if err := json.Unmarshal(fixture.Baseline, &snapshot); err != nil {
				t.Fatal(err)
			}
			for _, m := range scenario.Mutations {
				snapshot = applySchemaMutation(snapshot, m.Path, m.Op, m.Value).(map[string]any)
			}
			var calls []string
			connections := 0
			db := sql.OpenDB(schemaFixtureConnector{snapshot, &calls, &connections})
			defer db.Close()
			err := (OracleSessions{db}).CheckTwoFactorSchema(context.Background())
			if (err == nil) != scenario.Ready {
				t.Fatalf("ready=%v expected=%v error=%v", err == nil, scenario.Ready, err)
			}
			if connections != 1 {
				t.Fatalf("expected one live session, got %d", connections)
			}
			if len(calls) == 0 {
				t.Fatal("no database reads")
			}
		})
	}
}

func TestReadinessNeverCachesSuccess(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/two-factor-readiness.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Baseline map[string]any `json:"baseline"`
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid shared fixture")
	}
	var calls []string
	connections := 0
	db := sql.OpenDB(schemaFixtureConnector{fixture.Baseline, &calls, &connections})
	defer db.Close()
	repo := OracleSessions{db}
	if err = repo.CheckTwoFactorSchema(context.Background()); err != nil {
		t.Fatal("ready fixture rejected", err)
	}
	fixture.Baseline["owner"].(map[string]any)["schema"] = "DIFFERENT_OWNER"
	if err = repo.CheckTwoFactorSchema(context.Background()); err == nil {
		t.Fatal("stale readiness result accepted")
	}
}

func TestReadinessDatabaseFailuresAreSafe(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/two-factor-readiness.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Baseline map[string]any `json:"baseline"`
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid shared fixture")
	}
	fixture.Baseline["failOnQuery"] = "FROM USER_IND_COLUMNS"
	var calls []string
	connections := 0
	db := sql.OpenDB(schemaFixtureConnector{fixture.Baseline, &calls, &connections})
	defer db.Close()
	err = (OracleSessions{db}).CheckTwoFactorSchema(context.Background())
	if err == nil || strings.Contains(err.Error(), "synthetic-private") {
		t.Fatal("database error not safely mapped")
	}
	if len(calls) < 5 {
		t.Fatal("failure was not exercised after preceding metadata checks")
	}
}

type lateSchemaFailure struct {
	*factorFixture
	checks int
}

func (s *lateSchemaFailure) CheckTwoFactorSchema(context.Context) error {
	s.checks++
	if s.checks == 2 {
		return errSessionStore
	}
	return nil
}
func TestLoginRechecksSchemaBeforeCreatingChallenge(t *testing.T) {
	base, _, codec := newLoginFixture(t)
	base.twoFactor = true
	store := &lateSchemaFailure{factorFixture: &factorFixture{loginFixtureStore: base}}
	h := NewHandler(codec, store, CorsPolicy{})
	response := loginRequest(h, `{"account":"tester","password":"synthetic-password"}`)
	if response.Code != 503 || store.checks != 2 || store.challenge.ID != "" || len(base.inserted) != 0 || len(response.Result().Cookies()) != 0 {
		t.Fatalf("status=%d checks=%d challenge=%q sessions=%d", response.Code, store.checks, store.challenge.ID, len(base.inserted))
	}
}

func TestChallengeCompletionRejectsSchemaFailureWithoutConsuming(t *testing.T) {
	store, handler := challengeFixture(t)
	if response := loginRequest(handler, `{"account":"tester","password":"synthetic-password"}`); response.Code != 200 || store.challenge.ID == "" {
		t.Fatal("challenge not created")
	}
	store.schemaFail = true
	response := factorRequest(handler, `{"challenge_id":"`+store.challenge.ID+`","code":"287082"}`)
	if response.Code != 503 || store.consumed || len(store.inserted) != 0 || len(response.Result().Cookies()) != 0 {
		t.Fatalf("failed readiness authorized challenge: %d", response.Code)
	}
}

func TestChallengeRechecksSchemaBeforeReadingSecret(t *testing.T) {
	base, _, codec := newLoginFixture(t)
	store := &lateSchemaFailure{factorFixture: &factorFixture{loginFixtureStore: base, challenge: LoginChallenge{ID: "2fa-fixture", UserID: 42, Username: "tester"}, factor: factorSecretForTest(t, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")}}
	handler := NewHandler(codec, store, CorsPolicy{})
	response := factorRequest(handler, `{"challenge_id":"2fa-fixture","code":"287082"}`)
	if response.Code != 503 || store.checks != 2 || store.consumed || store.recoveryUsed || len(base.inserted) != 0 || len(response.Result().Cookies()) != 0 {
		t.Fatalf("status=%d checks=%d consumed=%v sessions=%d", response.Code, store.checks, store.consumed, len(base.inserted))
	}
}

func TestSharedMediaReadinessScenarios(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/media-readiness.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ID       string          `json:"id"`
		Baseline json.RawMessage `json:"baseline"`
		Cases    []struct {
			ID        string `json:"id"`
			Ready     bool   `json:"ready"`
			Mutations []struct {
				Op    string `json:"op"`
				Path  []any  `json:"path"`
				Value any    `json:"value"`
			} `json:"mutations"`
		} `json:"cases"`
	}
	if err = json.Unmarshal(data, &fixture); err != nil || fixture.ID != "MEDIA-READINESS" || len(fixture.Cases) != 14 {
		t.Fatal("invalid fixture", err)
	}
	for _, scenario := range fixture.Cases {
		t.Run(scenario.ID, func(t *testing.T) {
			var snapshot map[string]any
			if err := json.Unmarshal(fixture.Baseline, &snapshot); err != nil {
				t.Fatal(err)
			}
			for _, m := range scenario.Mutations {
				snapshot = applySchemaMutation(snapshot, m.Path, m.Op, m.Value).(map[string]any)
			}
			var calls []string
			connections := 0
			db := sql.OpenDB(schemaFixtureConnector{snapshot, &calls, &connections})
			defer db.Close()
			err := (OracleSessions{db}).CheckMediaSchema(context.Background())
			if (err == nil) != scenario.Ready {
				t.Fatalf("ready=%v expected=%v error=%v", err == nil, scenario.Ready, err)
			}
			if connections != 1 {
				t.Fatalf("expected one connection, got %d", connections)
			}
			if len(calls) == 0 {
				t.Fatal("no reads")
			}
		})
	}
}

func TestMediaReadinessRechecksAndRedactsFailures(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/media-readiness.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Baseline map[string]any `json:"baseline"`
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid fixture")
	}
	var calls []string
	connections := 0
	db := sql.OpenDB(schemaFixtureConnector{fixture.Baseline, &calls, &connections})
	defer db.Close()
	repo := OracleSessions{db}
	if err := repo.CheckMediaSchema(context.Background()); err != nil {
		t.Fatal("valid schema rejected", err)
	}
	before := len(calls)
	fixture.Baseline["failOnQuery"] = "FROM USER_TAB_COLUMNS"
	err = repo.CheckMediaSchema(context.Background())
	if err == nil || strings.Contains(err.Error(), "synthetic-private") {
		t.Fatal("database failure not safely rejected")
	}
	if len(calls) <= before {
		t.Fatal("expected repeated dictionary reads")
	}
}
