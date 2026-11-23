package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestParseGroupSettings(t *testing.T) {
	patch, bad := parseGroupSettings([]byte(`{"join_approval":false,"description":null,"tags":[" #猫","Rust","rust","  ","` + strings.Repeat("猫", 20) + `"],"unknown":"ignored"}`))
	if bad != "" || !patch.replaceTags || !reflect.DeepEqual(patch.tags, []string{"猫", "Rust", strings.Repeat("猫", 16)}) ||
		!reflect.DeepEqual(patch.fields, map[string]any{"join_approval": 0, "description": nil}) {
		t.Fatalf("patch=%+v error=%s", patch, bad)
	}
	for _, body := range []string{`[]`, `{"tags":null}`, `{"tags":[null]}`, `{"join_approval":"false"}`, `{"name":" "}`, `{"privacy":"global"}`} {
		if _, bad := parseGroupSettings([]byte(body)); bad == "" {
			t.Errorf("accepted %s", body)
		}
	}
	clear, bad := parseGroupSettings([]byte(`{"tags":[]}`))
	if bad != "" || !clear.replaceTags || len(clear.tags) != 0 {
		t.Fatalf("clear=%+v error=%s", clear, bad)
	}
	unchanged, bad := parseGroupSettings([]byte(`{}`))
	if bad != "" || unchanged.replaceTags || len(unchanged.fields) != 0 {
		t.Fatalf("unchanged=%+v error=%s", unchanged, bad)
	}
}

type groupSettingsFixture struct {
	state      driverState
	failure    string
	writes     int
	imageLocks int
}

const fixtureGroupImage = "posts/images/42/2026/11/12345678-1234-4321-8765-123456789abc.png"

type groupSettingsConn struct {
	*testConn
	f *groupSettingsFixture
}

func (*groupSettingsFixture) Driver() driver.Driver { return testDriver{} }
func (f *groupSettingsFixture) Connect(context.Context) (driver.Conn, error) {
	return &groupSettingsConn{&testConn{&f.state}, f}, nil
}

func (c *groupSettingsConn) QueryContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Rows, error) {
	switch stmt {
	case mediaReferences.LookupGroupImages:
		return &alertRows{values: []driver.Value{int64(11), fixtureGroupImage}}, nil
	case mediaReferences.LockGroupImage:
		c.f.imageLocks++
		if c.f.failure == "image-deleted" {
			return emptyRows{&c.f.state}, nil
		}
		return &alertRows{values: []driver.Value{"/storage/" + fixtureGroupImage}}, nil
	case directExtrasContract.SQL["asset_is_linked"]:
		if c.f.failure == "image-direct-linked" {
			return &alertRows{values: []driver.Value{int64(1)}}, nil
		}
		return emptyRows{&c.f.state}, nil
	case "SELECT seq_group_id.NEXTVAL AS id FROM dual":
		return &alertRows{values: []driver.Value{int64(7)}}, nil
	case membershipGroupSQL:
		return &alertRows{values: []driver.Value{int64(42), "public", int64(0), int64(1), int64(0)}}, nil
	case membershipReadSQL:
		return &alertRows{values: []driver.Value{"owner", "active"}}, nil
	case groupDetailSQL + "g.group_id=:group_id":
		return &alertRows{values: []driver.Value{int64(7), "Cat", "cat", nil, nil, nil, nil, int64(42), "public", "公开", int64(0), "all", int64(1), int64(0), int64(1), nil, nil, int64(42), "owner", "active", nil}}, nil
	case groupTagsSQL:
		return &alertRows{values: []driver.Value{"Rust"}}, nil
	case publicProfileSQL:
		if c.f.failure == "owner" {
			return nil, errors.New("owner read failed")
		}
		return &alertRows{values: []driver.Value{int64(42), "owner", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "offline", nil, "self"}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func TestGroupImageGuardUsesSameTransaction(t *testing.T) {
	for _, create := range []bool{true, false} {
		for _, failure := range []string{"", "image-deleted", "image-direct-linked"} {
			f := &groupSettingsFixture{failure: failure}
			db := sql.OpenDB(f)
			url := "https://old.example.test/uploads/" + fixtureGroupImage + "?preview=1"
			input, validation := parseNewGroup([]byte(`{"name":"Cat","avatar_url":"` + url + `","cover_url":"` + url + `"}`))
			if validation != "" {
				t.Fatal(validation)
			}
			var err error
			repository := OracleSessions{DB: db}
			if create {
				_, err = repository.CreateGroup(context.Background(), 42, input, StorageURLPolicy{})
			} else {
				_, err = repository.PatchGroupSettings(context.Background(), 42, 7, input, StorageURLPolicy{})
			}
			_ = db.Close()
			if f.imageLocks != 1 {
				t.Fatal(f.imageLocks)
			}
			if failure != "" {
				if !errors.Is(err, errGroupImageMissing) || f.writes != 0 || f.state.commits != 0 || f.state.rollbacks != 1 {
					t.Fatal(f, err)
				}
			} else if err != nil || f.writes == 0 || f.state.commits != 1 || input.fields["avatar_url"] != "/storage/"+fixtureGroupImage || input.fields["cover_url"] != "/storage/"+fixtureGroupImage {
				t.Fatal(f, err, input.fields)
			}
		}
	}
}

func (c *groupSettingsConn) ExecContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Result, error) {
	c.f.writes++
	if stmt == groupInsertTagSQL && c.f.failure == "tag" ||
		stmt == insertGroupOwnerSQL && c.f.failure == "membership" ||
		stmt == createGroupAuditSQL && c.f.failure == "audit" {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func TestCreateGroupUsesOneTransaction(t *testing.T) {
	input, invalid := parseNewGroup([]byte(`{"name":" Cat ","tags":["Rust","rust"]}`))
	if invalid != "" || input.fields["name"] != "Cat" || input.fields["privacy"] != "public" ||
		input.fields["join_approval"] != 0 || input.fields["post_permission"] != "all" ||
		!reflect.DeepEqual(input.tags, []string{"Rust"}) {
		t.Fatalf("input=%+v error=%s", input, invalid)
	}
	if _, invalid := parseNewGroup([]byte(`{}`)); invalid == "" {
		t.Fatal("missing name accepted")
	}
	if value := groupSlug(strings.Repeat("猫", 33), 9007199254740991); len(value) > 100 || !strings.HasSuffix(value, "-9007199254740991") {
		t.Fatalf("slug is overlong or lost its suffix: %s", value)
	}
	for _, tc := range []struct {
		failure string
		writes  int
	}{
		{"", 4}, {"membership", 2}, {"tag", 3}, {"audit", 4}, {"owner", 4},
	} {
		f := &groupSettingsFixture{failure: tc.failure}
		db := sql.OpenDB(f)
		group, err := (OracleSessions{DB: db}).CreateGroup(context.Background(), 42, input, StorageURLPolicy{})
		db.Close()
		commits := 0
		if tc.failure == "" {
			commits = 1
		}
		if (err != nil) != (tc.failure != "") || f.state.commits != commits || f.state.rollbacks != 1-commits || f.writes != tc.writes {
			t.Fatalf("failure=%q commits=%d rollbacks=%d writes=%d error=%v", tc.failure, f.state.commits, f.state.rollbacks, f.writes, err)
		}
		if err == nil && (group.Name != "Cat" || group.Owner.UserID != 42 || !reflect.DeepEqual(group.Tags, []string{"Rust"})) {
			t.Fatalf("group=%+v", group)
		}
	}
}

func TestGroupSettingsRollbackOnTagOrReadbackFailure(t *testing.T) {
	for _, failure := range []string{"", "tag", "owner"} {
		f := &groupSettingsFixture{failure: failure}
		db := sql.OpenDB(f)
		patch, _ := parseGroupSettings([]byte(`{"name":"Cat","tags":["Rust"]}`))
		group, err := (OracleSessions{DB: db}).PatchGroupSettings(context.Background(), 42, 7, patch, StorageURLPolicy{})
		db.Close()
		commits := 1
		if failure != "" {
			commits = 0
		}
		if (err != nil) != (failure != "") || f.state.commits != commits || f.state.rollbacks != 1-commits || f.writes != 3 {
			t.Fatalf("failure=%q commits=%d rollbacks=%d writes=%d error=%v", failure, f.state.commits, f.state.rollbacks, f.writes, err)
		}
		if err == nil && (group.Name != "Cat" || group.Owner.UserID != 42 || !reflect.DeepEqual(group.Tags, []string{"Rust"})) {
			t.Fatalf("group=%+v", group)
		}
	}
}
