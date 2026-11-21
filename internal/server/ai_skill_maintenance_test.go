package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"reflect"
	"testing"
)

func TestSkillMaintenancePlanDoesNotReadConfiguration(t *testing.T) {
	lookup := func(string) (string, bool) { t.Fatal("offline plan read environment"); return "", false }
	got, err := RunSkillMaintenance(context.Background(), []string{"--enabled-json", `["writing-draft","knowledge-answer"]`}, lookup)
	if want := (map[string]any{"mode": "plan", "connected": false, "enabled": []string{"knowledge-answer", "writing-draft"}}); err != nil || !reflect.DeepEqual(got, want) {
		t.Fatal(got, err)
	}
	for _, args := range [][]string{
		{"--publish", "--enabled-json", "[]"},
		{"--publish", "--expected", "01", "--enabled-json", "[]"},
		{"--enabled-json", `["writing-draft","writing-draft"]`},
		{"--status", "--enabled-json", "[]"},
	} {
		if _, err := RunSkillMaintenance(context.Background(), args, lookup); err == nil {
			t.Fatalf("accepted invalid arguments %v", args)
		}
	}
}

type skillWriteFixture struct {
	*testConn
	query string
	binds []driver.NamedValue
	count int64
	fail  error
}

type skillWriteFixtureConnector struct{ conn *skillWriteFixture }

func (c skillWriteFixtureConnector) Driver() driver.Driver { return testDriver{} }
func (c skillWriteFixtureConnector) Connect(context.Context) (driver.Conn, error) {
	return c.conn, nil
}

func (c *skillWriteFixture) ExecContext(_ context.Context, query string, binds []driver.NamedValue) (driver.Result, error) {
	c.query, c.binds = query, binds
	return driver.RowsAffected(c.count), c.fail
}

func TestSkillPublicationChecksGenerationAndDoesNotReplayCommit(t *testing.T) {
	for _, tc := range []struct {
		name        string
		expected    int64
		count       int64
		writeError  error
		commitError bool
		want        error
	}{
		{"initialize", 0, 1, nil, false, nil},
		{"same generation", 2, 1, nil, false, nil},
		{"stale", 2, 0, nil, false, errSkillConflict},
		{"already initialized", 0, 0, emailUniqueError{}, false, errSkillConflict},
		{"unknown commit", 2, 1, nil, true, errSkillCommit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &driverState{}
			if tc.commitError {
				state.fail = "commit"
			}
			fixture := &skillWriteFixture{testConn: &testConn{state}, count: tc.count, fail: tc.writeError}
			db := sql.OpenDB(skillWriteFixtureConnector{fixture})
			defer db.Close()
			tx, err := db.BeginTx(context.Background(), nil)
			if err != nil {
				t.Fatal(err)
			}
			err = publishSkillConfig(context.Background(), tx, tc.expected, []string{})
			if !errors.Is(err, tc.want) {
				t.Fatal(err, tc.want)
			}
			if len(fixture.binds) == 0 || fixture.binds[0].Value != "[]" {
				t.Fatal(fixture.binds)
			}
			if tc.expected == 0 {
				if fixture.query != skillWrite.Queries.Insert || len(fixture.binds) != 1 {
					t.Fatal(fixture.query, fixture.binds)
				}
			} else if fixture.query != skillWrite.Queries.Update || len(fixture.binds) != 2 || fixture.binds[1].Value != tc.expected {
				t.Fatal(fixture.query, fixture.binds)
			}
			if tc.want == errSkillConflict && (state.commits != 0 || state.rollbacks != 1) {
				t.Fatal(state)
			}
			if tc.want != errSkillConflict && state.commits != 1 {
				t.Fatal(state)
			}
		})
	}
}
