package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
	"time"
)

type tagRepoConnector struct {
	calls *[]listQueryCall
	state *driverState
}
type tagRepoConn struct {
	*testConn
	calls *[]listQueryCall
}

func (c tagRepoConnector) Connect(context.Context) (driver.Conn, error) {
	return &tagRepoConn{&testConn{c.state}, c.calls}, nil
}
func (c tagRepoConnector) Driver() driver.Driver { return testDriver{} }
func (c *tagRepoConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	*c.calls = append(*c.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	for _, arg := range args {
		if arg.Name == "start_row" && arg.Value == float64(4) {
			return &alertRows{values: []driver.Value{nil, nil, nil, nil, nil, nil, int64(3)}}, nil
		}
	}
	return &alertRows{values: []driver.Value{int64(17), "Cat", int64(42), 12.5, int64(1), time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC), int64(3)}}, nil
}
func TestTagRepositoryBindsAndMaps(t *testing.T) {
	for _, trending := range []bool{false, true} {
		var calls []listQueryCall
		db := sql.OpenDB(tagRepoConnector{&calls, &driverState{}})
		q := "%cat_%"
		query := TagListQuery{Page: SessionPage{Page: 2, PageSize: 1, Start: 2, End: 2}, Trending: trending}
		if !trending {
			query.Q = &q
		}
		items, total, err := (OracleSessions{db}).ListTags(context.Background(), query)
		_ = db.Close()
		if err != nil || total != 3 || len(items) != 1 || items[0].TrendingScore != 12.5 || items[0].UpdatedAt != "2026-01-02T03:04:05.000Z" {
			t.Fatalf("items=%#v total=%d err=%v", items, total, err)
		}
		if len(calls) != 1 || !strings.Contains(calls[0].sql, "trending_score DESC, usage_count DESC, updated_at DESC, tag_id DESC") || !strings.HasSuffix(calls[0].sql, "ORDER BY p.rn") {
			t.Fatal(calls)
		}
		if trending {
			if !strings.Contains(calls[0].sql, "is_trending = 1") || len(calls[0].args) != 2 {
				t.Fatal(calls)
			}
		} else {
			if strings.Contains(calls[0].sql, "cat_%") || len(calls[0].args) != 3 || calls[0].args[0].Value != q {
				t.Fatal(calls)
			}
		}
	}
}

func TestTagRepositoryBindsNullForEmptySearch(t *testing.T) {
	var calls []listQueryCall
	db := sql.OpenDB(tagRepoConnector{&calls, &driverState{}})
	defer db.Close()
	query := TagListQuery{Page: SessionPage{Page: 1, PageSize: 20, Start: 1, End: 20}}
	if _, _, err := (OracleSessions{db}).ListTags(context.Background(), query); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || len(calls[0].args) != 3 || calls[0].args[0].Name != "q" || calls[0].args[0].Value != nil {
		t.Fatal("empty query must bind NULL", calls)
	}
}

func TestTagRepositoryEmptyPagePreservesTotal(t *testing.T) {
	var calls []listQueryCall
	db := sql.OpenDB(tagRepoConnector{&calls, &driverState{}})
	defer db.Close()
	query := TagListQuery{Page: SessionPage{Page: 4, PageSize: 1, Start: 4, End: 4}}
	items, total, err := (OracleSessions{db}).ListTags(context.Background(), query)
	if err != nil || total != 3 || len(items) != 0 || len(calls) != 1 {
		t.Fatal(items, total, calls, err)
	}
}
