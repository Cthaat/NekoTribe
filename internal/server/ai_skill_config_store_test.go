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

type skillConfigState struct {
	conversation conversationDB
	rows         [][]driver.Value
	fail         bool
	calls        int
	schemaBroken bool
	query        string
}
type skillConfigConnector struct{ state *skillConfigState }
type skillConfigConn struct {
	*conversationConn
	state *skillConfigState
}
type skillConfigRows struct {
	rows  [][]driver.Value
	index int
}

func (c skillConfigConnector) Connect(context.Context) (driver.Conn, error) {
	return &skillConfigConn{&conversationConn{&testConn{&c.state.conversation.driverState}, &c.state.conversation}, c.state}, nil
}
func (skillConfigConnector) Driver() driver.Driver { return testDriver{} }
func (c *skillConfigConn) QueryContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	if strings.Contains(strings.ToLower(q), "from n_ai_skill_config") {
		c.state.calls++
		c.state.query = q
		if c.state.fail {
			return nil, errors.New("secret")
		}
		if len(args) != 1 || args[0].Name != "singleton_id" || args[0].Value != int64(1) {
			return nil, errors.New("invalid bind")
		}
		return &skillConfigRows{rows: c.state.rows}, nil
	}
	if strings.Contains(strings.ToLower(q), "user_tables") || strings.Contains(strings.ToLower(q), "user_tab_columns") || strings.Contains(strings.ToLower(q), "user_constraints") || strings.Contains(strings.ToLower(q), "user_cons_columns") || strings.Contains(strings.ToLower(q), "n_schema_migrations") || strings.Contains(strings.ToLower(q), "sys_context") {
		data, err := os.ReadFile("../../contracts/scenarios/ai-skill-readiness.json")
		if err != nil {
			return nil, err
		}
		var fixture struct {
			Baseline map[string]any `json:"baseline"`
		}
		if err = json.Unmarshal(data, &fixture); err != nil {
			return nil, err
		}
		if c.state.schemaBroken {
			delete(fixture.Baseline["tables"].(map[string]any), "N_AI_SKILL_CONFIG")
		}
		var calls []string
		var connections int
		return (&schemaFixtureConn{schemaFixtureConnector{fixture.Baseline, &calls, &connections}}).QueryContext(ctx, q, args)
	}
	return c.conversationConn.QueryContext(ctx, q, args)
}

func TestSkillConfigLockUsesCallerTransaction(t *testing.T) {
	state := &skillConfigState{rows: [][]driver.Value{{int64(7), `["knowledge-answer"]`}}}
	db := sql.OpenDB(skillConfigConnector{state})
	defer db.Close()
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	config, err := lockSkillRegistry(context.Background(), tx, 42)
	if err != nil || config.Generation != 7 || !strings.HasSuffix(strings.ToUpper(strings.TrimSpace(state.query)), "FOR UPDATE NOWAIT") {
		t.Fatal(config, err, state.query)
	}
	if _, err = lockSkillRegistry(context.Background(), nil, 42); !errors.Is(err, errSkillConfigUnavailable) {
		t.Fatal(err)
	}
}

func TestKnowledgeSkillSelectionClosesReadTransactionBeforeReturning(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	for _, enabled := range []bool{true, false} {
		value := `[]`
		if enabled {
			value = `["knowledge-answer"]`
		}
		state := &skillConfigState{conversation: conversationDB{owner: 42, id: id, purpose: "knowledge"}, rows: [][]driver.Value{{int64(7), value}}}
		db := sql.OpenDB(skillConfigConnector{state})
		generation, err := (OracleSessions{db}).selectAISkillOperation(context.Background(), 42, id, conversationPolicy("", ""), nil, func(context.Context, *sql.Conn) error { return nil })
		db.Close()
		if (err == nil) != enabled || (enabled && generation != 7) || state.conversation.rollbacks != 1 || state.conversation.commits != 0 || strings.Contains(strings.ToUpper(state.query), "FOR UPDATE") {
			t.Fatal(generation, err, state.conversation, state.query)
		}
	}
}

func TestSkillConfigRejectsSchemaBeforeReadingConfiguration(t *testing.T) {
	state := &skillConfigState{schemaBroken: true, rows: [][]driver.Value{{int64(1), `[]`}}}
	db := sql.OpenDB(skillConfigConnector{state})
	defer db.Close()
	if _, err := loadSkillRegistry(context.Background(), db, 42); !errors.Is(err, errSkillConfigUnavailable) || state.calls != 0 {
		t.Fatal(err, state.calls)
	}
}
func (r *skillConfigRows) Columns() []string { return []string{"GENERATION", "ENABLED_IDS"} }
func (r *skillConfigRows) Close() error      { return nil }
func (r *skillConfigRows) Next(dest []driver.Value) error {
	if r.index == len(r.rows) {
		return io.EOF
	}
	copy(dest, r.rows[r.index])
	r.index++
	return nil
}

func TestSkillConfigReloadsDurableSettingsAndChecksAuthorization(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	state := &skillConfigState{conversation: conversationDB{owner: 42, id: id, purpose: "group", group: int64(7)}, rows: [][]driver.Value{{int64(2), `["group-brief"]`}}}
	db := sql.OpenDB(skillConfigConnector{state})
	defer db.Close()
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	result, err := selectConfiguredConversationSkill(context.Background(), tx, 42, id, nil, conversationPolicy("", ""))
	if err != nil || result.Generation != 2 || result.Skill.ID != "group-brief" || state.conversation.permissionCalls < 1 {
		t.Fatal(result, err)
	}
	state.rows = [][]driver.Value{{int64(3), `[]`}}
	if _, err = selectConfiguredConversationSkill(context.Background(), tx, 42, id, nil, conversationPolicy("", "")); err == nil {
		t.Fatal("disabled skill selected")
	}
	if state.calls != 2 {
		t.Fatal(state.calls)
	}
	state.rows = [][]driver.Value{{int64(4), `["group-brief"]`}}
	state.conversation.mode = "denied"
	if _, err = selectConfiguredConversationSkill(context.Background(), tx, 42, id, nil, conversationPolicy("", "")); err == nil {
		t.Fatal("revoked group accepted")
	}
}
func TestSkillConfigRejectsMissingCorruptAndUnavailable(t *testing.T) {
	valid := []driver.Value{int64(1), `[]`}
	cases := [][][]driver.Value{nil, {valid, valid}, {{int64(0), `[]`}}, {{float64(1.5), `[]`}}, {{int64(1000000000000000), `[]`}}, {{int64(1), `null`}}, {{int64(1), `["unknown"]`}}, {{int64(1), `["writing-draft","writing-draft"]`}}, {{int64(1), strings.Repeat(" ", 513)}}, {{int64(1), `[null]`}}}
	for _, rows := range cases {
		state := &skillConfigState{rows: rows}
		db := sql.OpenDB(skillConfigConnector{state})
		_, err := loadSkillRegistry(context.Background(), db, 42)
		db.Close()
		if !errors.Is(err, errSkillConfigUnavailable) {
			t.Fatal(rows, err)
		}
	}
	state := &skillConfigState{fail: true}
	db := sql.OpenDB(skillConfigConnector{state})
	defer db.Close()
	if _, err := loadSkillRegistry(context.Background(), db, 42); !errors.Is(err, errSkillConfigUnavailable) {
		t.Fatal(err)
	}
	calls := state.calls
	if _, err := loadSkillRegistry(context.Background(), db, 0); err == nil || state.calls != calls {
		t.Fatal(err, state.calls)
	}
}
