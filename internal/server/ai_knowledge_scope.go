package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type knowledgeScope string

const (
	knowledgePublic     knowledgeScope = "public"
	knowledgePersonal   knowledgeScope = "personal"
	knowledgeGroup      knowledgeScope = "group"
	maxKnowledgeGroupID int64          = 9007199254740991
)

func (scope knowledgeScope) valid() bool {
	return scope == knowledgePublic || scope == knowledgePersonal || scope == knowledgeGroup
}

func (scope knowledgeScope) restricted() bool {
	return scope == knowledgePersonal || scope == knowledgeGroup
}

type knowledgeScopeContract struct {
	GroupIndexPath string            `json:"group_index_path"`
	SQL            map[string]string `json:"sql"`
}

var scopedKnowledgeContract = sync.OnceValue(func() knowledgeScopeContract {
	var contract knowledgeScopeContract
	if json.Unmarshal(contracts.AIKnowledgeScope, &contract) != nil {
		return knowledgeScopeContract{}
	}
	return contract
})

func requireKnowledgeGroupMember(ctx context.Context, db publicProfileQueryer, viewer int64, groupID *int64) error {
	return checkKnowledgeGroupMembership(ctx, db, scopedKnowledgeContract().SQL["membership"], viewer, groupID)
}

func checkKnowledgeGroupMembership(ctx context.Context, db publicProfileQueryer, query string, viewer int64, groupID *int64) error {
	if query == "" || groupID == nil || *groupID <= 0 || *groupID > maxKnowledgeGroupID {
		return errSessionStore
	}
	var member int64
	err := db.QueryRowContext(ctx, query, sql.Named("viewer_id", viewer), sql.Named("group_id", *groupID)).Scan(&member)
	if errors.Is(err, sql.ErrNoRows) {
		return errConversationForbidden
	}
	if err != nil || member <= 0 {
		return errSessionStore
	}
	return nil
}

func lockKnowledgeGroup(ctx context.Context, tx *sql.Tx, viewer int64, groupID *int64) error {
	if err := requireKnowledgeGroupMember(ctx, tx, viewer, groupID); err != nil {
		return err
	}
	query := scopedKnowledgeContract().SQL["lock_group"]
	if query == "" {
		return errSessionStore
	}
	var locked int64
	err := tx.QueryRowContext(ctx, query, sql.Named("group_id", *groupID)).Scan(&locked)
	if errors.Is(err, sql.ErrNoRows) {
		return errConversationForbidden
	}
	if err != nil || locked != *groupID {
		return errSessionStore
	}
	return checkKnowledgeGroupMembership(ctx, tx, scopedKnowledgeContract().SQL["lock_membership"], viewer, groupID)
}

type scopedKnowledgeStore interface {
	knowledgeStoreForConversation(conversationInput) knowledgeServiceStore
}

type restrictedKnowledgeStore struct {
	db     *sql.DB
	access conversationInput
}

func (s OracleSessions) knowledgeStoreForConversation(access conversationInput) knowledgeServiceStore {
	return restrictedKnowledgeStore{db: s.DB, access: access}
}

func (s restrictedKnowledgeStore) discoverKnowledgeSources(ctx context.Context, viewer int64, query string, limit int) ([]knowledgeSource, error) {
	if address := os.Getenv("AI_KNOWLEDGE_INDEX_URL"); s.access.KnowledgeScope == knowledgeGroup && address != "" {
		if err := requireKnowledgeGroupMember(ctx, s.db, viewer, s.access.GroupID); err != nil {
			return nil, err
		}
		rows, err := discoverScopedIndexedKnowledge(ctx, viewer, address, query, limit, s.access.GroupID)
		if !errors.Is(err, errKnowledgeIndexTransient) || ctx.Err() != nil {
			return rows, err
		}
	}
	return s.discoverLexicalKnowledgeSources(ctx, viewer, query, limit)
}

func (s restrictedKnowledgeStore) discoverLexicalKnowledgeSources(ctx context.Context, viewer int64, query string, limit int) ([]knowledgeSource, error) {
	reader := scopedKnowledgeReader{conn: s.db, access: s.access}
	if s.access.KnowledgeScope == knowledgeGroup {
		if err := requireKnowledgeGroupMember(ctx, s.db, viewer, s.access.GroupID); err != nil {
			return nil, err
		}
		return discoverKnowledgeByKinds(ctx, reader, viewer, query, limit, []string{"group_post", "group_comment"})
	}
	return discoverKnowledgeByKinds(ctx, reader, viewer, query, limit, []string{"post"})
}

func (s restrictedKnowledgeStore) hydrateKnowledgeSources(ctx context.Context, viewer int64, candidates []knowledgeCandidate) ([]knowledgeSource, error) {
	return hydrateConversationKnowledge(ctx, s.db, viewer, s.access, candidates, false)
}

type scopedKnowledgeReader struct {
	conn   knowledgeQueryer
	access conversationInput
}

func (r scopedKnowledgeReader) sourceQuery(kind string, search bool) string {
	key := kind
	switch r.access.KnowledgeScope {
	case knowledgeGroup:
		if !isGroupKnowledgeKind(kind) {
			return ""
		}
	case knowledgePersonal:
		if kind != "post" {
			return ""
		}
		key = "personal_post"
	default:
		return ""
	}
	if search {
		key = "search_" + key
	}
	return scopedKnowledgeContract().SQL[key]
}

func (r scopedKnowledgeReader) get(ctx context.Context, viewer int64, candidate knowledgeCandidate) (knowledgeSource, bool, error) {
	query := r.sourceQuery(candidate.Kind, false)
	if query == "" {
		return knowledgeSource{}, false, nil
	}
	row, found, err := queryKnowledgeSource(ctx, r.conn, query, candidate.Kind, r.bindings(query, viewer, sql.Named("source_id", candidate.ID))...)
	if found && r.access.GroupID != nil && row.GroupID != *r.access.GroupID {
		return knowledgeSource{}, false, nil
	}
	return row, found, err
}

func (r scopedKnowledgeReader) search(ctx context.Context, viewer int64, kind, term string, limit int) ([]knowledgeSource, error) {
	query := r.sourceQuery(kind, true)
	if query == "" {
		return nil, errSessionStore
	}
	rows, err := queryKnowledgeSearch(ctx, r.conn, query, kind, limit, r.bindings(query, viewer, sql.Named("term", term), sql.Named("row_limit", limit))...)
	if err == nil && r.access.GroupID != nil {
		for _, row := range rows {
			if row.GroupID != *r.access.GroupID {
				return nil, errKnowledgeSourceChanged
			}
		}
	}
	return rows, err
}

func (r scopedKnowledgeReader) bindings(query string, viewer int64, extra ...any) []any {
	args := []any{sql.Named("viewer_id", viewer)}
	if strings.Contains(query, ":max_id") {
		args = append(args, sql.Named("max_id", knowledgeMaxID))
	}
	if r.access.GroupID != nil {
		args = append(args, sql.Named("group_id", *r.access.GroupID))
	}
	return append(args, extra...)
}

func hydrateConversationKnowledge(ctx context.Context, db interface {
	knowledgeQueryer
	publicProfileQueryer
}, viewer int64, access conversationInput, refs []knowledgeCandidate, locked bool) ([]knowledgeSource, error) {
	if access.KnowledgeScope == knowledgeGroup {
		if err := requireKnowledgeGroupMember(ctx, db, viewer, access.GroupID); err != nil {
			return nil, err
		}
	}
	if access.KnowledgeScope.restricted() {
		rows, err := hydrateKnowledge(ctx, scopedKnowledgeReader{conn: db, access: access}, viewer, refs)
		if err == nil && access.KnowledgeScope == knowledgeGroup && len(rows) != len(refs) {
			err = requireKnowledgeGroupMember(ctx, db, viewer, access.GroupID)
		}
		return rows, err
	}
	if locked {
		return hydrateKnowledge(ctx, lockedKnowledgeReader{db}, viewer, refs)
	}
	return hydrateKnowledge(ctx, oracleKnowledgeReader{db}, viewer, refs)
}

func restoreConversationKnowledgeMessage(ctx context.Context, tx *sql.Tx, viewer int64, access conversationInput, content string, locked bool) (knowledgeRestored, error) {
	message, err := restoreKnowledgeMessage(ctx, content, func(ctx context.Context, refs []knowledgeCandidate) ([]knowledgeSource, error) {
		return hydrateConversationKnowledge(ctx, tx, viewer, access, refs, locked)
	})
	if err == nil && access.KnowledgeScope.restricted() != (len(message.Dependencies) > 0) {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	return message, err
}
