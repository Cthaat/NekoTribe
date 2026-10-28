package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
)

type analyticsConnector struct{ state *driverState }
type analyticsConn struct{ *testConn }

func (c analyticsConnector) Connect(context.Context) (driver.Conn, error) {
	return &analyticsConn{&testConn{c.state}}, nil
}
func (c analyticsConnector) Driver() driver.Driver { return testDriver{} }
func (c *analyticsConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.sql = q
	c.state.args = args
	return &alertRows{values: []driver.Value{"C# cats", int64(2), int64(1), int64(30), int64(4), 2.75}}, nil
}
func TestTagAnalyticsRepositoryFiltersByViewer(t *testing.T) {
	s := &driverState{}
	db := sql.OpenDB(analyticsConnector{s})
	defer db.Close()
	result, found, err := (OracleSessions{db}).ReadTagAnalytics(context.Background(), 42, "C# cats")
	if err != nil || !found || result.TotalPosts != 2 || result.EngagementScore != 2.75 {
		t.Fatal(result, found, err)
	}
	for _, fragment := range []string{"p.is_deleted=0", "fn_can_view_post(:viewer_id,p.post_id)=1", "COUNT(DISTINCT p.post_id)", "LOWER(:name)"} {
		if !strings.Contains(s.sql, fragment) {
			t.Fatal("missing", fragment)
		}
	}
	if strings.Contains(s.sql, "C# cats") || len(s.args) != 2 || s.args[0].Value != int64(42) || s.args[1].Value != "C# cats" {
		t.Fatal(s.args)
	}
}
