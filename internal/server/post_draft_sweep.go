package server

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"time"
)

const (
	postDraftSavepoint = "SAVEPOINT post_draft_publish"
	postDraftRollback  = "ROLLBACK TO SAVEPOINT post_draft_publish"
)

// RunPostDraftSweep processes a bounded batch of due drafts on each tick.
func (s OracleSessions) RunPostDraftSweep(ctx context.Context, config RefreshConfig) {
	ticker := time.NewTicker(time.Duration(postDrafts.SweepInterval) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			batch, cancel := context.WithTimeout(ctx, 25*time.Second)
			err := s.sweepPostDrafts(batch, config)
			cancel()
			if err != nil && !errors.Is(err, errPostDraftUnavailable) && ctx.Err() == nil {
				log.Print("post draft sweep incomplete")
			}
		}
	}
}

func (s OracleSessions) sweepPostDrafts(ctx context.Context, config RefreshConfig) error {
	results, err := s.publishPostDraftBatch(ctx, config.Storage)
	for _, published := range results {
		s.notifyDraftPublication(ctx, config, published)
	}
	return err
}

func (s OracleSessions) publishPostDraftBatch(ctx context.Context, storage StorageURLPolicy) ([]postDraftResult, error) {
	conn, err := s.postDraftConnection(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	ids, err := postDraftCandidates(ctx, conn)
	if err != nil {
		return nil, err
	}
	var results []postDraftResult
	var failed error
	for _, id := range ids {
		if ctx.Err() != nil {
			return results, ctx.Err()
		}
		result, err := postDraftTx(ctx, conn, func(tx *sql.Tx) (postDraftResult, error) {
			return publishDuePostDraft(ctx, tx, id, storage)
		})
		if err != nil {
			failed = err
		} else if result.newPostID != 0 {
			results = append(results, result)
		}
	}
	return results, failed
}

func postDraftCandidates(ctx context.Context, conn *sql.Conn) ([]int64, error) {
	rows, err := conn.QueryContext(ctx, postDrafts.SQL["candidates"])
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	ids := make([]int64, 0, postDrafts.SweepBatch)
	for len(ids) < postDrafts.SweepBatch && rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil || id < 1 || id > maxSocketID {
			return nil, errSessionStore
		}
		ids = append(ids, id)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, errSessionStore
	}
	return ids, nil
}

func publishDuePostDraft(ctx context.Context, tx *sql.Tx, id int64, storage StorageURLPolicy) (postDraftResult, error) {
	draft, err := scanPostDraft(tx.QueryRowContext(ctx, postDrafts.SQL["lock_due"], sql.Named("draft_id", id)))
	if errors.Is(err, errPostDraftMissing) {
		return postDraftResult{}, nil
	}
	if err != nil {
		return postDraftResult{}, err
	}
	if _, err := tx.ExecContext(ctx, postDraftSavepoint); err != nil {
		return postDraftResult{}, errSessionStore
	}
	result, err := publishPostDraft(ctx, tx, draft, storage)
	if err == nil {
		return result, nil
	}
	var reason string
	switch postDraftFailure(err).status {
	case 400:
		reason = "content_unavailable"
	case 403, 404, 422:
		reason = "permission_denied"
	default:
		return postDraftResult{}, err
	}
	if _, err := tx.ExecContext(ctx, postDraftRollback); err != nil {
		return postDraftResult{}, errSessionStore
	}
	err = writeOneChatRow(ctx, tx, postDrafts.SQL["failed"], sql.Named("draft_id", id), sql.Named("owner_id", draft.owner),
		sql.Named("reason", reason))
	return postDraftResult{}, err
}
