package server

import (
	"context"
	"database/sql"
	"errors"
	"testing"
)

func TestGroupEvidenceUsesBoundScopeAndDistinguishesDenialFromStoreFailure(t *testing.T) {
	ctx := context.Background()
	state := &driverState{}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()

	search := "群公告"
	end := "2026-11-17T12:00:00.000000"
	request := groupEvidenceQuery{LookbackDays: 7, SearchTerm: &search, MatchExcerpt: true, WindowEnd: &end}
	_, err := readGroupEvidence(ctx, db, 42, 9, request)
	if !errors.Is(err, errConversationForbidden) {
		t.Fatalf("empty scope isn't access denied: %v", err)
	}
	if state.sql != groupEvidenceSQL || state.commits != 0 {
		t.Fatal("expected one read of the shared SQL")
	}
	want := map[string]interface{}{
		"actor_id": int64(42), "group_id": int64(9), "lookback_days": int64(7),
		"search_term": search, "match_excerpt": int64(1), "window_end": end,
	}
	for _, arg := range state.args {
		if want[arg.Name] != arg.Value {
			t.Fatalf("unexpected bind %s", arg.Name)
		}
		delete(want, arg.Name)
	}
	if len(want) != 0 {
		t.Fatalf("missing binds: %v", want)
	}

	state.sql = ""
	request.LookbackDays = 900
	if _, err := readGroupEvidence(ctx, db, 42, 9, request); !errors.Is(err, errConversationInvalid) || state.sql != "" {
		t.Fatalf("invalid window reached the database: %v", err)
	}
	request.LookbackDays = 30
	state.fail = "query"
	if _, err := readGroupEvidence(ctx, db, 42, 9, request); !errors.Is(err, errSessionStore) {
		t.Fatalf("store failure escaped or was mistaken for denial: %v", err)
	}
}
