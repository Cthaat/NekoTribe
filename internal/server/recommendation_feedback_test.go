package server

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"testing"
)

type feedbackCase struct {
	ID, Method, Path                       string
	Status                                 int
	Anonymous, SchemaMissing, WriteFailure bool
	Body                                   json.RawMessage
	Normalized                             *struct {
		Type, Action, Reason string
		ID                   int64
	}
}

type feedbackConnector struct {
	resetTransactionConnector
	test     *testing.T
	scenario feedbackCase
}

func (c feedbackConnector) Connect(context.Context) (driver.Conn, error) {
	return &feedbackConn{&resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, c}, nil
}

type feedbackConn struct {
	*resetTransactionConn
	fixture feedbackConnector
}

func (c *feedbackConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	var row appealRows
	switch query {
	case recommendationFeedbackSQL.Schema:
		if !c.fixture.scenario.SchemaMissing {
			row = appealRows{"N_RECOMMENDATION_FEEDBACK"}
		}
	case recommendationFeedbackSQL.LockActor:
		if len(args) != 1 || args[0].Name != "actor_id" || args[0].Value != int64(42) {
			c.fixture.test.Fatal(args)
		}
		row = appealRows{int64(42)}
	default:
		valid := false
		for _, target := range recommendationFeedbackSQL.Targets {
			valid = valid || target == query
		}
		if !valid {
			c.fixture.test.Fatal(query)
		}
		id := args[0].Value.(int64)
		if id != 2 && id != 9 {
			row = appealRows{id}
		}
	}
	return &row, nil
}

func (c *feedbackConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if query != recommendationFeedbackSQL.Save {
		c.fixture.test.Fatal(query)
	}
	if want := c.fixture.scenario.Normalized; want != nil {
		got := map[string]driver.Value{}
		for _, arg := range args {
			got[arg.Name] = arg.Value
		}
		if got["actor_id"] != int64(42) || got["resource_type"] != want.Type || got["resource_id"] != want.ID ||
			got["action"] != want.Action || got["reason"] != nullablePostString(want.Reason) {
			c.fixture.test.Fatal(got, want)
		}
	}
	if c.fixture.scenario.WriteFailure {
		return nil, errors.New("isolated write failure")
	}
	return driver.RowsAffected(1), nil
}

func TestRecommendationFeedbackSharedScenarios(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/recommendation-feedback.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct{ Cases []feedbackCase }
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, tc := range spec.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			state := &resetTransactionState{}
			db := sql.OpenDB(feedbackConnector{resetTransactionConnector{state}, t, tc})
			defer db.Close()
			app := NewHandler(codec, likersRouteStore{OracleSessions{db}}, CorsPolicy{})
			r := httptest.NewRequest(tc.Method, tc.Path, bytes.NewReader(tc.Body))
			r.Header.Set("Content-Type", "application/json")
			if !tc.Anonymous {
				r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			w := httptest.NewRecorder()
			app.ServeHTTP(w, r)
			if w.Code != tc.Status || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("%d %s", w.Code, w.Body.String())
			}
			switch tc.Status {
			case 200:
				var response struct{ Data struct{ Accepted bool } }
				if json.Unmarshal(w.Body.Bytes(), &response) != nil || !response.Data.Accepted || state.commits != 1 || state.rollbacks != 0 {
					t.Fatal(w.Body.String(), state.commits, state.rollbacks)
				}
			case 404, 500, 503:
				if state.commits != 0 || state.rollbacks != 1 {
					t.Fatal(state.commits, state.rollbacks)
				}
			}
		})
	}
}
