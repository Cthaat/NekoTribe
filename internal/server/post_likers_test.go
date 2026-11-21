package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"slices"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type likersConnector struct {
	t     *testing.T
	reads *int
}

func (c likersConnector) Driver() driver.Driver { return testDriver{} }
func (c likersConnector) Connect(context.Context) (driver.Conn, error) {
	return likersConn{testConn: &testConn{&driverState{}}, likersConnector: c}, nil
}

type likersConn struct {
	*testConn
	likersConnector
}

type likerRows [][]driver.Value

func (*likerRows) Columns() []string { return make([]string, 16) }
func (*likerRows) Close() error      { return nil }
func (r *likerRows) Next(dest []driver.Value) error {
	if len(*r) == 0 {
		return io.EOF
	}
	copy(dest, (*r)[0])
	*r = (*r)[1:]
	return nil
}

func (c likersConn) QueryContext(_ context.Context, statement string, binds []driver.NamedValue) (driver.Rows, error) {
	(*c.reads)++
	if statement != postLikersSQL || len(binds) != 4 ||
		binds[0].Name != "post_id" || binds[1].Name != "viewer_id" || binds[1].Value != int64(42) ||
		binds[2].Name != "start_row" || binds[3].Name != "end_row" {
		c.t.Fatal(statement, binds)
	}
	row := func(user, total int64) []driver.Value {
		return []driver.Value{user, "liker", nil, "Liker", nil, nil, nil, nil, nil, nil, nil, nil, "offline", nil, "none", total}
	}
	switch binds[0].Value {
	case int64(1):
		switch [2]any{binds[2].Value, binds[3].Value} {
		case [2]any{float64(1), float64(2)}:
			return &likerRows{row(8, 3), row(7, 3)}, nil
		case [2]any{float64(3), float64(4)}:
			return &likerRows{row(9, 3)}, nil
		case [2]any{float64(5), float64(6)}:
			return &likerRows{row(0, 3)}, nil
		}
		c.t.Fatal("bad page bounds", binds)
	case int64(4):
		return &likerRows{row(0, 0)}, nil
	}
	return &likerRows{}, nil
}

type likersRouteStore struct{ OracleSessions }

func (likersRouteStore) Touch(_ context.Context, claims auth.Claims) (int64, error) {
	if claims.UserID == 42 {
		return 1, nil
	}
	return 0, nil
}

func TestPostLikersSharedScenarios(t *testing.T) {
	type meta struct {
		Page     int
		PageSize int `json:"page_size"`
		Total    int
		HasNext  bool `json:"has_next"`
	}
	b, err := os.ReadFile("../../contracts/scenarios/post-likers.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Cases []struct {
			ID, Method, Path string
			Status           int
			Anonymous        bool
			IDs              []int64
			Meta             meta
		}
	}
	if err := json.Unmarshal(b, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	reads := 0
	db := sql.OpenDB(likersConnector{t, &reads})
	defer db.Close()
	app := NewHandler(codec, likersRouteStore{OracleSessions{db}}, CorsPolicy{})
	for _, tc := range spec.Cases {
		r := httptest.NewRequest(tc.Method, tc.Path, nil)
		if !tc.Anonymous {
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		w := httptest.NewRecorder()
		before := reads
		app.ServeHTTP(w, r)
		if w.Code != tc.Status || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: %d %s", tc.ID, w.Code, w.Body.String())
		}
		wantReads := 0
		if tc.Status == 200 || tc.Status == 404 {
			wantReads = 1
		}
		if reads-before != wantReads {
			t.Fatal(tc.ID, reads-before)
		}
		if tc.Status == 200 {
			var out struct {
				Data []PublicUser
				Meta meta
			}
			if json.Unmarshal(w.Body.Bytes(), &out) != nil || out.Data == nil || out.Meta != tc.Meta {
				t.Fatal(w.Body.String())
			}
			var ids []int64
			for _, user := range out.Data {
				ids = append(ids, user.UserID)
			}
			if !slices.Equal(ids, tc.IDs) {
				t.Fatal(tc.ID, ids)
			}
		}
	}
}
