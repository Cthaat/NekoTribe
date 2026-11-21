package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
)

func TestSharedSkillSelectionVectors(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/ai-skill-selection-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID        string   `json:"id"`
			Enabled   []string `json:"enabled"`
			Purpose   string   `json:"purpose"`
			GroupID   *int64   `json:"groupId"`
			SkillID   *string  `json:"skillId"`
			Allowed   bool     `json:"allowed"`
			Expected  string   `json:"expected"`
			Selection string   `json:"selection"`
			Error     bool     `json:"error"`
		} `json:"cases"`
	}
	if err = json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	for _, v := range vectors.Cases {
		t.Run(v.ID, func(t *testing.T) {
			registry, e := newSkillRegistry(v.Enabled)
			if e != nil {
				if !v.Error {
					t.Fatal(e)
				}
				return
			}
			calls := 0
			result, e := registry.selectSkill(context.Background(), skillScope{ActorID: 7, Purpose: v.Purpose, GroupID: v.GroupID}, v.SkillID, func(_ context.Context, scope skillScope) error {
				calls++
				if scope.ActorID != 7 || scope.Purpose != v.Purpose || !reflect.DeepEqual(scope.GroupID, v.GroupID) {
					t.Fatal(scope)
				}
				if !v.Allowed {
					return errors.New("private")
				}
				return nil
			})
			if v.Error {
				if e == nil {
					t.Fatal("expected rejection")
				}
				return
			}
			if e != nil || result.ID != v.Expected || result.Version != 1 || result.Selection != v.Selection || calls != 1 {
				t.Fatal(result, e, calls)
			}
		})
	}
}
func TestSkillSelectionCopiesAndRechecksAuthorization(t *testing.T) {
	enabled := []string{"group-brief"}
	registry, err := newSkillRegistry(enabled)
	if err != nil {
		t.Fatal(err)
	}
	enabled[0] = "writing-draft"
	group := int64(42)
	scope := skillScope{ActorID: 7, Purpose: "group", GroupID: &group}
	calls := 0
	authorize := func(context.Context, skillScope) error { calls++; return nil }
	a, err := registry.selectSkill(context.Background(), scope, nil, authorize)
	if err != nil {
		t.Fatal(err)
	}
	a.Tools[0] = "publish"
	*a.GroupID = 3
	b, err := registry.selectSkill(context.Background(), scope, nil, authorize)
	if err != nil || b.Tools[0] == "publish" || *b.GroupID != 42 || calls != 2 {
		t.Fatal(b, err, calls)
	}
	if _, err = registry.selectSkill(context.Background(), scope, nil, func(context.Context, skillScope) error { return errors.New("secret") }); !errors.Is(err, errSkillUnavailable) {
		t.Fatal(err)
	}
}
func TestSkillConversationChecksRealOwnerAndGroupPermission(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	state := &conversationDB{owner: 42, id: id, purpose: "group", group: int64(7)}
	db := sql.OpenDB(conversationConnector{state})
	defer db.Close()
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	registry, err := newSkillRegistry([]string{"group-brief"})
	if err != nil {
		t.Fatal(err)
	}
	result, err := selectConversationSkill(context.Background(), tx, registry, 42, id, nil, conversationPolicy("", ""))
	if err != nil || result.ID != "group-brief" || state.permissionCalls < 1 {
		t.Fatal(result, err, state)
	}
	state.mode = "denied"
	if _, err = selectConversationSkill(context.Background(), tx, registry, 42, id, nil, conversationPolicy("", "")); err == nil {
		t.Fatal("revoked group accepted")
	}
}
