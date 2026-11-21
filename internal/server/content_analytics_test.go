package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

type contentAnalyticsConnector struct {
	t     *testing.T
	reads *int
}

func (c contentAnalyticsConnector) Driver() driver.Driver { return testDriver{} }

func (c contentAnalyticsConnector) Connect(context.Context) (driver.Conn, error) {
	return contentAnalyticsConn{&testConn{&driverState{}}, c}, nil
}

type contentAnalyticsConn struct {
	*testConn
	contentAnalyticsConnector
}

type analyticsRows [][]driver.Value

func (r *analyticsRows) Columns() []string {
	if len(*r) == 0 {
		return nil
	}
	return make([]string, len((*r)[0]))
}
func (*analyticsRows) Close() error { return nil }
func (r *analyticsRows) Next(dest []driver.Value) error {
	if len(*r) == 0 {
		return io.EOF
	}
	copy(dest, (*r)[0])
	*r = (*r)[1:]
	return nil
}

func (c contentAnalyticsConn) QueryContext(_ context.Context, statement string, binds []driver.NamedValue) (driver.Rows, error) {
	(*c.reads)++
	if len(binds) < 2 || binds[0].Name != "target_id" || binds[1].Name != "viewer_id" || binds[1].Value != int64(42) {
		c.t.Fatal(statement, binds)
	}
	id := binds[0].Value
	rows := analyticsRows{}
	switch statement {
	case contentAnalyticsSQL.Post:
		switch id {
		case int64(1):
			rows = append(rows, []driver.Value{int64(1), int64(1), int64(1), int64(3), int64(2), int64(2), int64(1), int64(3), 4.25, .6667})
		case int64(7):
			rows = append(rows, []driver.Value{int64(7), int64(1), int64(7), int64(0), int64(8), int64(2), int64(1), int64(3), 4.25, 0.0})
		case int64(13):
			rows = append(rows, []driver.Value{int64(13), int64(1), nil, int64(0), int64(0), int64(0), int64(0), int64(0), 0.0, 0.0})
		case int64(8):
			rows = append(rows, []driver.Value{int64(8), int64(0), nil, int64(0), int64(0), int64(0), int64(0), int64(0), 0.0, 0.0})
		}
	case contentAnalyticsSQL.Summary:
		switch id {
		case int64(42):
			rows = append(rows, []driver.Value{int64(42), int64(3), int64(2), int64(3), int64(10), 5.0, int64(1), int64(1), 4.25})
		case int64(8):
			rows = append(rows, []driver.Value{int64(8), int64(1), int64(1), int64(1), int64(5), 5.0, int64(0), int64(0), 3.5})
		case int64(12):
			rows = append(rows, []driver.Value{int64(12), int64(0), int64(0), int64(0), int64(0), 0.0, int64(0), int64(0), 0.0})
		}
	case contentAnalyticsSQL.Daily:
		if id != int64(42) || len(binds) != 3 || binds[2].Name != "days" {
			c.t.Fatal(binds)
		}
		for range binds[2].Value.(int64) {
			rows = append(rows, []driver.Value{"2026-11-17", int64(1), int64(1), int64(1), int64(1), int64(1), int64(1), int64(3)})
		}
	default:
		c.t.Fatal("unexpected SQL", statement)
	}
	return &rows, nil
}

func TestContentAnalyticsSharedScenarios(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/content-analytics.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Cases []struct {
			ID, Method, Path     string
			Status, Length       int
			Anonymous, SkipQuery bool
			Data                 map[string]any
		}
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	reads := 0
	db := sql.OpenDB(contentAnalyticsConnector{t, &reads})
	defer db.Close()
	app := NewHandler(codec, likersRouteStore{OracleSessions{db}}, CorsPolicy{})
	for _, tc := range spec.Cases {
		path := strings.Replace(tc.Path, "/users/1/analytics", "/users/42/analytics", 1)
		r := httptest.NewRequest(tc.Method, path, nil)
		if !tc.Anonymous {
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		w := httptest.NewRecorder()
		before := reads
		app.ServeHTTP(w, r)
		if w.Code != tc.Status || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: %d %s", tc.ID, w.Code, w.Body.String())
		}
		wantReads := 1
		if tc.Anonymous || tc.SkipQuery || tc.Status == 400 {
			wantReads = 0
		}
		if reads-before != wantReads {
			t.Fatal(tc.ID, reads-before)
		}
		if tc.Status != 200 {
			continue
		}
		var out struct {
			Data any
			Meta any
		}
		if json.Unmarshal(w.Body.Bytes(), &out) != nil || out.Meta != nil {
			t.Fatal(w.Body.String())
		}
		if tc.Length > 0 {
			if rows, ok := out.Data.([]any); !ok || len(rows) != tc.Length {
				t.Fatal(tc.ID, w.Body.String())
			}
		} else {
			if tc.Data["user_id"] == float64(1) {
				tc.Data["user_id"] = float64(42)
			}
			if !reflect.DeepEqual(out.Data, tc.Data) {
				t.Fatal(tc.ID, w.Body.String(), tc.Data)
			}
		}
	}
}
