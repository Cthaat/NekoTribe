package server

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

type conversationPage struct {
	Items      []conversationRecord `json:"items"`
	NextCursor *string              `json:"next_cursor"`
}
type conversationListTx interface {
	fetch(context.Context, int64, string, int, bool, string, *int64, string, knowledgeScope) ([]conversationRecord, error)
	authorize(context.Context, int64, conversationInput, moderationPolicy) error
}

func validListPurpose(purpose string) bool {
	switch purpose {
	case "", "knowledge", "writing", "group", "moderation":
		return true
	default:
		return false
	}
}

func listConversationPage(ctx context.Context, tx conversationListTx, user int64, after string, limit int, purpose string, groupID *int64, targetTitle string, knowledgeFilter knowledgeScope, policy moderationPolicy) (conversationPage, error) {
	empty := conversationPage{Items: []conversationRecord{}}
	if user <= 0 || user > 9007199254740991 || (after != "" && !conversationUUID.MatchString(after)) || limit < 1 || limit > 50 || !validListPurpose(purpose) {
		return empty, errConversationInvalid
	}
	if groupID != nil && (purpose != "group" || *groupID < 1 || *groupID > 9007199254740991) {
		return empty, errConversationInvalid
	}
	if targetTitle != "" && purpose != "moderation" {
		return empty, errConversationInvalid
	}
	if knowledgeFilter != "" {
		if !knowledgeFilter.valid() || (purpose != "" && purpose != "knowledge") {
			return empty, errConversationInvalid
		}
		purpose = "knowledge"
	}
	moderationAllowed := true
	if err := tx.authorize(ctx, user, conversationInput{Purpose: "moderation"}, policy); err != nil {
		if !errors.Is(err, errConversationForbidden) {
			return empty, errSessionStore
		}
		moderationAllowed = false
	}
	scanAfter := strings.ToLower(after)
	page := conversationPage{Items: []conversationRecord{}}
	for batch := 0; batch < 10; batch++ {
		rows, err := tx.fetch(ctx, user, scanAfter, limit+1, moderationAllowed, purpose, groupID, targetTitle, knowledgeFilter)
		if err != nil {
			return empty, errSessionStore
		}
		for _, record := range rows {
			if !conversationUUID.MatchString(record.ID) || record.ID <= scanAfter || (purpose != "" && record.Purpose != purpose) ||
				(knowledgeFilter != "" && record.KnowledgeScope != knowledgeFilter) ||
				(groupID != nil && (record.GroupID == nil || *record.GroupID != *groupID)) ||
				(targetTitle != "" && (record.Title == nil || *record.Title != targetTitle || record.GroupID != nil)) {
				return empty, errSessionStore
			}
			scanAfter = record.ID
			scope, err := validateConversationInput(record.access())
			if err != nil {
				return empty, errSessionStore
			}
			if err = tx.authorize(ctx, user, scope, policy); err != nil {
				if errors.Is(err, errConversationForbidden) {
					continue
				}
				return empty, errSessionStore
			}
			if len(page.Items) == limit {
				cursor := page.Items[len(page.Items)-1].ID
				page.NextCursor = &cursor
				return page, nil
			}
			page.Items = append(page.Items, record)
		}
		if len(rows) < limit+1 {
			return page, nil
		}
		if len(page.Items) > 0 {
			cursor := page.Items[len(page.Items)-1].ID
			page.NextCursor = &cursor
			return page, nil
		}
	}
	return empty, errSessionStore
}

type oracleConversationList struct{ tx *sql.Tx }

func (o oracleConversationList) authorize(ctx context.Context, user int64, input conversationInput, policy moderationPolicy) error {
	return authorizeConversation(ctx, o.tx, user, input, policy)
}
func (o oracleConversationList) fetch(ctx context.Context, user int64, after string, limit int, moderationAllowed bool, purpose string, groupID *int64, targetTitle string, knowledgeFilter knowledgeScope) ([]conversationRecord, error) {
	var cursor any
	if after != "" {
		cursor = after
	}
	allowed := 0
	if moderationAllowed {
		allowed = 1
	}
	var scope any
	if purpose != "" {
		scope = purpose
	}
	var title any
	if targetTitle != "" {
		title = targetTitle
	}
	rows, err := o.tx.QueryContext(ctx, `SELECT c.conversation_id,c.owner_user_id,c.purpose,c.group_id,c.knowledge_scope,c.title,c.created_at,c.updated_at
FROM n_ai_conversations c WHERE c.owner_user_id=:owner_user_id
AND (:after_id IS NULL OR c.conversation_id>:after_id)
AND (:purpose IS NULL OR c.purpose=:purpose)
AND (:group_id IS NULL OR c.group_id=:group_id)
AND (:target_title IS NULL OR (c.title=:target_title AND c.group_id IS NULL))
AND (:knowledge_scope IS NULL OR c.knowledge_scope=:knowledge_scope)
AND (c.purpose='writing' OR (c.purpose='knowledge' AND (c.knowledge_scope<>'group' OR EXISTS (
  SELECT 1 FROM n_group_members gm JOIN n_groups g ON g.group_id=gm.group_id AND g.is_active=1 AND g.is_deleted=0
  WHERE gm.group_id=c.group_id AND gm.user_id=:owner_user_id AND gm.status='active'
))) OR (c.purpose='group' AND fn_has_group_permission(:owner_user_id,c.group_id,'admin')=1) OR (c.purpose='moderation' AND :moderation_allowed=1))
ORDER BY c.conversation_id ASC FETCH FIRST :row_limit ROWS ONLY`, sql.Named("owner_user_id", user), sql.Named("after_id", cursor), sql.Named("purpose", scope), sql.Named("group_id", groupID), sql.Named("target_title", title), sql.Named("knowledge_scope", nullableRegistration(string(knowledgeFilter))), sql.Named("moderation_allowed", allowed), sql.Named("row_limit", limit))
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	result := []conversationRecord{}
	for rows.Next() {
		var r conversationRecord
		var owner int64
		var group sql.NullInt64
		var storedScope knowledgeScope
		var title sql.NullString
		var created, updated sql.NullTime
		if rows.Scan(&r.ID, &owner, &r.Purpose, &group, &storedScope, &title, &created, &updated) != nil || owner != user || r.readKnowledgeScope(storedScope) != nil {
			return nil, errSessionStore
		}
		if group.Valid {
			value := group.Int64
			r.GroupID = &value
		}
		r.Title = nullableString(title)
		if value := profileDate(created); value != nil {
			r.CreatedAt = *value
		}
		if value := profileDate(updated); value != nil {
			r.UpdatedAt = *value
		}
		result = append(result, r)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, errSessionStore
	}
	return result, nil
}

func (s OracleSessions) listAIConversations(ctx context.Context, user int64, after string, limit int, purpose string, groupID *int64, targetTitle string, knowledgeFilter knowledgeScope, policy moderationPolicy) (conversationPage, error) {
	return s.listAIConversationsOperation(ctx, user, after, limit, purpose, groupID, targetTitle, knowledgeFilter, policy, verifyConversationSchema)
}
func (s OracleSessions) listAIConversationsOperation(ctx context.Context, user int64, after string, limit int, purpose string, groupID *int64, targetTitle string, knowledgeFilter knowledgeScope, policy moderationPolicy, verify func(context.Context, *sql.Conn) error) (result conversationPage, err error) {
	if user <= 0 || user > 9007199254740991 || (after != "" && !conversationUUID.MatchString(after)) || limit < 1 || limit > 50 {
		return result, errConversationInvalid
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return result, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			result = conversationPage{}
			err = errSessionStore
		}
	}()
	if verify(ctx, conn) != nil {
		return result, errConversationSchema
	}
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return result, errSessionStore
	}
	committed := false
	defer func() {
		if !committed && tx.Rollback() != nil {
			result = conversationPage{}
			err = errSessionStore
		}
	}()
	result, e = listConversationPage(ctx, oracleConversationList{tx}, user, after, limit, purpose, groupID, targetTitle, knowledgeFilter, policy)
	if e != nil {
		return conversationPage{}, e
	}
	committed = true
	if tx.Commit() != nil {
		return conversationPage{}, errSessionStore
	}
	return result, nil
}
