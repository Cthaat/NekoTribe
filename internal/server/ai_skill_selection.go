package server

import (
	"context"
	"database/sql"
	"errors"
)

var errSkillUnavailable = errors.New("SKILL_UNAVAILABLE")

type skillScope struct {
	ActorID int64
	Purpose string
	GroupID *int64
}
type skillSelection struct {
	skillScope
	ID        string
	Version   int
	Selection string
	Tools     []string
}
type skillRegistry struct{ enabled map[string]bool }
type skillDefinition struct {
	id, purpose string
	version     int
	tools       []string
}

var skillDefinitions = [...]skillDefinition{
	{id: "knowledge-answer", purpose: "knowledge", version: 1, tools: []string{"public_search"}},
	{id: "writing-draft", purpose: "writing", version: 1},
	{id: "group-brief", purpose: "group", version: 1, tools: []string{"public_search", "public_statistics"}},
	{id: "moderation-advice", purpose: "moderation", version: 1, tools: []string{"public_search"}},
}

func skillForPurpose(purpose string) (skillDefinition, bool) {
	for _, item := range skillDefinitions {
		if item.purpose == purpose {
			return item, true
		}
	}
	return skillDefinition{}, false
}
func knownSkill(id string) bool {
	for _, item := range skillDefinitions {
		if item.id == id {
			return true
		}
	}
	return false
}
func newSkillRegistry(enabled []string) (*skillRegistry, error) {
	if enabled == nil {
		return nil, errSkillUnavailable
	}
	out := &skillRegistry{enabled: map[string]bool{}}
	for _, id := range enabled {
		if !knownSkill(id) || out.enabled[id] {
			return nil, errSkillUnavailable
		}
		out.enabled[id] = true
	}
	return out, nil
}
func cloneSkillScope(scope skillScope) skillScope {
	if scope.GroupID != nil {
		v := *scope.GroupID
		scope.GroupID = &v
	}
	return scope
}

// Authorization must be supplied by the current backend, not by a client or model.
func (r *skillRegistry) selectSkill(ctx context.Context, scope skillScope, id *string, authorize func(context.Context, skillScope) error) (skillSelection, error) {
	item, ok := skillForPurpose(scope.Purpose)
	if r == nil || !ok || scope.ActorID < 1 || scope.ActorID > 9007199254740991 || (scope.Purpose == "group" && (scope.GroupID == nil || *scope.GroupID < 1 || *scope.GroupID > 999999999999999)) || (scope.Purpose != "group" && scope.GroupID != nil) || (id != nil && (*id == "" || *id != item.id)) || !r.enabled[item.id] || authorize == nil {
		return skillSelection{}, errSkillUnavailable
	}
	scope = cloneSkillScope(scope)
	if ctx.Err() != nil || authorize(ctx, cloneSkillScope(scope)) != nil {
		return skillSelection{}, errSkillUnavailable
	}
	selection := "explicit"
	if id == nil {
		selection = "purpose-default"
	}
	return skillSelection{skillScope: cloneSkillScope(scope), ID: item.id, Version: item.version, Selection: selection, Tools: append([]string{}, item.tools...)}, nil
}

// The identity is authenticated by the caller; the owned conversation and its
// current group or moderation permission are reloaded from the transaction.
func selectConversationSkill(ctx context.Context, tx *sql.Tx, registry *skillRegistry, actor int64, id string, skillID *string, policy moderationPolicy) (skillSelection, error) {
	if tx == nil || actor < 1 || actor > 9007199254740991 || !conversationUUID.MatchString(id) {
		return skillSelection{}, errSkillUnavailable
	}
	record, err := readConversationRow(ctx, tx, actor, id, policy, false)
	if err != nil {
		return skillSelection{}, errSkillUnavailable
	}
	scope := skillScope{ActorID: actor, Purpose: record.Purpose, GroupID: record.GroupID}
	return registry.selectSkill(ctx, scope, skillID, func(ctx context.Context, s skillScope) error {
		return authorizeConversation(ctx, tx, s.ActorID, conversationInput{Purpose: s.Purpose, GroupID: s.GroupID}, policy)
	})
}
