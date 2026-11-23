package server

import (
	"context"
	"database/sql"
	"errors"
	"testing"
)

type listingFixture struct {
	records   []conversationRecord
	forbidden map[string]bool
	fail      bool
	seenUser  int64
	moderator bool
}

func TestConversationListingRepositoryUsesOwnerAndClosesTransaction(t *testing.T) {
	id := "0f9da41c-7296-4f51-91f4-141f5c6e3c01"
	state := &conversationDB{owner: 42, id: id}
	db := sql.OpenDB(conversationConnector{state})
	defer db.Close()
	page, err := (OracleSessions{db}).listAIConversationsOperation(context.Background(), 42, "", 2, "", nil, "", "", conversationPolicy("", "other"), func(context.Context, *sql.Conn) error { return nil })
	if err != nil || len(page.Items) != 1 || page.Items[0].ID != id || page.NextCursor != nil || state.commits != 1 {
		t.Fatal(page, err, state)
	}
}

func (f *listingFixture) fetch(_ context.Context, user int64, after string, limit int, moderator bool, purpose string, groupID *int64, _ string, scope knowledgeScope) ([]conversationRecord, error) {
	f.seenUser = user
	f.moderator = moderator
	out := []conversationRecord{}
	for _, record := range f.records {
		if record.ID > after && len(out) < limit && (purpose == "" || record.Purpose == purpose) && (groupID == nil || (record.GroupID != nil && *record.GroupID == *groupID)) && (scope == "" || scope == record.KnowledgeScope) {
			out = append(out, record)
		}
	}
	return out, nil
}
func (f *listingFixture) authorize(_ context.Context, _ int64, input conversationInput, _ moderationPolicy) error {
	if input.Purpose == "moderation" {
		return errConversationForbidden
	}
	if f.fail && input.Purpose == "group" {
		return errors.New("database failure")
	}
	if input.GroupID != nil && f.forbidden[input.Purpose] {
		return errConversationForbidden
	}
	return nil
}

func TestConversationListingRespectsVisibilityAndCursor(t *testing.T) {
	ids := []string{"0f9da41c-7296-4f51-91f4-141f5c6e3c01", "1f9da41c-7296-4f51-91f4-141f5c6e3c01", "2f9da41c-7296-4f51-91f4-141f5c6e3c01"}
	group := int64(7)
	tx := &listingFixture{records: []conversationRecord{{ID: ids[0], Purpose: "writing"}, {ID: ids[1], Purpose: "group", GroupID: &group}, {ID: ids[2], Purpose: "knowledge"}}, forbidden: map[string]bool{"group": true}}
	page, err := listConversationPage(context.Background(), tx, 42, "", 1, "", nil, "", "", conversationPolicy("", ""))
	if err != nil || len(page.Items) != 1 || page.Items[0].ID != ids[0] || page.NextCursor == nil || *page.NextCursor != ids[0] || tx.seenUser != 42 || tx.moderator {
		t.Fatal(page, err)
	}
	next, err := listConversationPage(context.Background(), tx, 42, *page.NextCursor, 1, "", nil, "", "", conversationPolicy("", ""))
	if err != nil || len(next.Items) != 1 || next.Items[0].ID != ids[2] || next.NextCursor == nil || *next.NextCursor != ids[2] {
		t.Fatal(next, err)
	}
	tx.fail = true
	if _, err = listConversationPage(context.Background(), tx, 42, ids[0], 1, "", nil, "", "", conversationPolicy("", "")); err == nil {
		t.Fatal("permission failure must not become empty results")
	}
	filtered, err := listConversationPage(context.Background(), tx, 42, "", 1, "knowledge", nil, "", "", conversationPolicy("", ""))
	if err != nil || len(filtered.Items) != 1 || filtered.Items[0].ID != ids[2] || filtered.NextCursor != nil {
		t.Fatal(filtered, err)
	}
	tx.fail = false
	denied, err := listConversationPage(context.Background(), tx, 42, "", 1, "group", &group, "", "", conversationPolicy("", ""))
	if err != nil || len(denied.Items) != 0 || denied.NextCursor != nil {
		t.Fatal(denied, err)
	}
	tx.forbidden["group"] = false
	allowed, err := listConversationPage(context.Background(), tx, 42, "", 1, "group", &group, "", "", conversationPolicy("", ""))
	if err != nil || len(allowed.Items) != 1 || allowed.Items[0].ID != ids[1] || allowed.NextCursor != nil {
		t.Fatal(allowed, err)
	}
	if _, err = listConversationPage(context.Background(), tx, 42, "bad", 1, "", nil, "", "", conversationPolicy("", "")); !errors.Is(err, errConversationInvalid) {
		t.Fatal(err)
	}
}
