package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

func (s OracleSessions) postDraftConnection(ctx context.Context) (*sql.Conn, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errSessionStore
	}
	var catalog schemaCatalog
	if json.Unmarshal(contracts.PostDraftsSchemaCatalog, &catalog) != nil ||
		validateFeatureSchema(ctx, conn, catalog, "post-drafts") != nil {
		_ = conn.Close()
		return nil, errPostDraftUnavailable
	}
	return conn, nil
}

func scanPostDraft(row interface{ Scan(...any) error }) (*postDraftRecord, error) {
	var draft postDraftRecord
	var group, published sql.NullInt64
	var scheduled, lastError sql.NullString
	var payload string
	err := row.Scan(&draft.ID, &draft.owner, &group, &payload, &draft.Status, &scheduled, &published, &lastError, &draft.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errPostDraftMissing
	}
	if err != nil {
		return nil, errSessionStore
	}
	input, err := parsePostDraft([]byte(payload))
	if err != nil || input.group.group != group.Int64 || group.Valid != (input.group.group != 0) ||
		draft.ID < 1 || draft.ID > maxSocketID || draft.owner < 1 ||
		draft.Status == "published" && (!published.Valid || published.Int64 < 1 || published.Int64 > maxSocketID) {
		return nil, errSessionStore
	}
	draft.group, draft.PublishedID = nullableInt(group), nullableInt(published)
	draft.ScheduledAt, draft.LastError = nullableString(scheduled), nullableString(lastError)
	draft.Payload, draft.input = input.json, input
	return &draft, nil
}

func (s OracleSessions) ListPostDrafts(ctx context.Context, owner int64, query postDraftQuery) (postDraftList, error) {
	if query.limit < 1 || query.limit > postDrafts.MaxLimit {
		return postDraftList{}, errPostDraftInvalid
	}
	conn, err := s.postDraftConnection(ctx)
	if err != nil {
		return postDraftList{}, err
	}
	defer conn.Close()
	rows, err := conn.QueryContext(ctx, postDrafts.SQL["list"], sql.Named("owner_id", owner), sql.Named("before_id", nullableViewer(query.before)),
		sql.Named("group_scope", nullableViewer(query.group)), sql.Named("fetch_limit", query.limit+1))
	if err != nil {
		return postDraftList{}, errSessionStore
	}
	defer rows.Close()
	result := postDraftList{Items: make([]postDraftRecord, 0, query.limit)}
	for rows.Next() {
		if len(result.Items) == query.limit {
			result.NextBefore = &result.Items[len(result.Items)-1].ID
			break
		}
		draft, err := scanPostDraft(rows)
		if err != nil {
			return postDraftList{}, err
		}
		result.Items = append(result.Items, *draft)
	}
	if rows.Err() != nil {
		return postDraftList{}, errSessionStore
	}
	return result, nil
}

type postDraftResult struct {
	record    *postDraftRecord
	newPostID int64
}

func postDraftTx(ctx context.Context, conn *sql.Conn, work func(*sql.Tx) (postDraftResult, error)) (postDraftResult, error) {
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return postDraftResult{}, errSessionStore
	}
	defer tx.Rollback()
	result, err := work(tx)
	if err != nil {
		if rollback := tx.Rollback(); rollback != nil && !errors.Is(rollback, sql.ErrTxDone) {
			return postDraftResult{}, errSessionStore
		}
		return postDraftResult{}, err
	}
	if tx.Commit() != nil {
		return postDraftResult{}, errSessionStore
	}
	return result, nil
}

func (s OracleSessions) ChangePostDraft(ctx context.Context, owner int64, action postDraftAction, config RefreshConfig) (*postDraftRecord, error) {
	conn, err := s.postDraftConnection(ctx)
	if err != nil {
		return nil, err
	}
	result, err := postDraftTx(ctx, conn, func(tx *sql.Tx) (postDraftResult, error) {
		return changePostDraft(ctx, tx, owner, action, config.Storage)
	})
	_ = conn.Close()
	if err != nil {
		return nil, err
	}
	s.notifyDraftPublication(ctx, config, result)
	return result.record, nil
}

func changePostDraft(ctx context.Context, tx *sql.Tx, owner int64, action postDraftAction, storage StorageURLPolicy) (postDraftResult, error) {
	user := sql.Named("owner_id", owner)
	if action.kind == "create" {
		if err := tx.QueryRowContext(ctx, "SELECT seq_post_draft_id.NEXTVAL FROM dual").Scan(&action.id); err != nil ||
			action.id < 1 || action.id > maxSocketID {
			return postDraftResult{}, errSessionStore
		}
	}
	key := []any{sql.Named("draft_id", action.id), user}
	if action.kind == "remove" {
		removed, err := postTxExecute(ctx, tx, postDrafts.SQL["remove"], key...)
		if err != nil || removed > 1 {
			return postDraftResult{}, errSessionStore
		}
		if removed == 0 {
			return postDraftResult{}, errPostDraftMissing
		}
		return postDraftResult{}, nil
	}
	var previous *postDraftRecord
	if action.kind != "create" {
		var err error
		previous, err = scanPostDraft(tx.QueryRowContext(ctx, postDrafts.SQL["lock_owner"], key...))
		if err != nil {
			return postDraftResult{}, err
		}
		if action.kind == "publish" {
			return publishPostDraft(ctx, tx, previous, storage)
		}
		if previous.Status == "published" {
			return postDraftResult{}, errPostDraftPublished
		}
	}
	binds := append([]any(nil), key...)
	statement := postDrafts.SQL[action.kind]
	switch action.kind {
	case "create", "edit":
		if action.kind == "create" {
			statement = postDrafts.SQL["insert"]
		}
		var group any
		if action.body.group.group != 0 {
			group = action.body.group.group
		}
		binds = append(binds, sql.Named("group_id", group), sql.Named("payload_json", string(action.body.json)))
	case "schedule":
		if err := validatePostDraftSchedule(ctx, tx, previous, action.when); err != nil {
			return postDraftResult{}, err
		}
		binds = append(binds, sql.Named("scheduled_at", action.when.Format(postUTCDateLayout)))
	case "unschedule":
	default:
		return postDraftResult{}, errSessionStore
	}
	changed, err := postTxExecute(ctx, tx, statement, binds...)
	if err != nil {
		return postDraftResult{}, err
	}
	if action.kind == "schedule" && changed == 0 {
		return postDraftResult{}, errPostDraftSchedule
	}
	if changed != 1 {
		return postDraftResult{}, errSessionStore
	}
	draft, err := scanPostDraft(tx.QueryRowContext(ctx, postDrafts.SQL["read"], key...))
	return postDraftResult{record: draft}, err
}

func validatePostDraftSchedule(ctx context.Context, tx *sql.Tx, draft *postDraftRecord, scheduled time.Time) error {
	in := draft.input
	poll := in.regular.Poll
	markdown := in.regular.Markdown
	if draft.group != nil {
		poll = in.group.poll
		markdown = in.group.markdown
	}
	if poll != nil && !poll.closesAt.After(scheduled) {
		return errPostDraftPollCutoff
	}
	if draft.group == nil {
		if _, err := preparePostCreation(draft.owner, in.regular); err != nil {
			return err
		}
		if err := checkPublishAccess(ctx, tx, draft.owner); err != nil {
			return err
		}
	} else {
		if in.group.content == "" {
			return errPostContentEmpty
		}
		if err := lockGroupContent(ctx, tx, sql.Named("user_id", draft.owner), sql.Named("group_id", *draft.group)); err != nil {
			return err
		}
		if err := requireGroupPostCreationAccess(ctx, tx, draft.owner, in.group); err != nil {
			return err
		}
	}
	return checkPostCreationExtras(ctx, tx, poll, markdown)
}

func publishPostDraft(ctx context.Context, tx *sql.Tx, draft *postDraftRecord, storage StorageURLPolicy) (postDraftResult, error) {
	if draft.Status == "published" {
		return postDraftResult{record: draft}, nil
	}
	owner, in := draft.owner, draft.input
	var postID int64
	if draft.group == nil {
		creation, err := preparePostCreation(owner, in.regular)
		if err != nil {
			return postDraftResult{}, err
		}
		if err := checkPostCreationExtras(ctx, tx, creation.Poll, creation.Markdown); err != nil {
			return postDraftResult{}, err
		}
		postID, err = creation.reserveID(ctx, tx, owner)
		if err != nil {
			return postDraftResult{}, err
		}
		if postID < 1 || postID > maxSocketID {
			return postDraftResult{}, errSessionStore
		}
		if err := creation.write(ctx, tx, owner, postID); err != nil {
			return postDraftResult{}, err
		}
	} else {
		if in.group.content == "" {
			return postDraftResult{}, errPostContentEmpty
		}
		if err := checkPostCreationExtras(ctx, tx, in.group.poll, in.group.markdown); err != nil {
			return postDraftResult{}, err
		}
		if err := lockGroupContent(ctx, tx, sql.Named("user_id", owner), sql.Named("group_id", *draft.group)); err != nil {
			return postDraftResult{}, err
		}
		var err error
		postID, err = createGroupPostOn(ctx, tx, owner, in.group, storage)
		if err != nil {
			return postDraftResult{}, err
		}
	}
	key := []any{sql.Named("draft_id", draft.ID), sql.Named("owner_id", owner)}
	if err := writeOneChatRow(ctx, tx, postDrafts.SQL["published"], append(key, sql.Named("post_id", postID))...); err != nil {
		return postDraftResult{}, err
	}
	record, err := scanPostDraft(tx.QueryRowContext(ctx, postDrafts.SQL["read"], key...))
	return postDraftResult{record: record, newPostID: postID}, err
}

func (s OracleSessions) notifyDraftPublication(ctx context.Context, config RefreshConfig, result postDraftResult) {
	if result.newPostID == 0 {
		return
	}
	draft := result.record
	var err error
	if draft.group == nil {
		err = notifyPostCreated(ctx, s, s, config, draft.owner, result.newPostID, draft.input.regular)
	} else {
		err = notifyGroupPost(ctx, s, s, config, draft.owner, groupPost{
			ID: result.newPostID, Group: *draft.group, Content: draft.input.group.content,
		})
	}
	if err != nil {
		log.Print("post draft publication notification unavailable")
	}
}
