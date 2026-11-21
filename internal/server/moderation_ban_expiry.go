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

type banExpiryPolicy struct {
	SQL             map[string]string
	IntervalSeconds int
}

var banExpiry = func() banExpiryPolicy {
	var contract banExpiryPolicy
	if err := json.Unmarshal(contracts.ModerationBanExpiryContract, &contract); err != nil {
		panic("invalid moderation ban-expiry contract")
	}
	return contract
}()

var banExpirySQL = banExpiry.SQL

func (s OracleSessions) restoreExpiredBan(ctx context.Context, user int64) error {
	return s.restoreBan(ctx, user, banExpirySQL["lock"])
}

func (s OracleSessions) restoreBan(ctx context.Context, user int64, lock string) error {
	_, err := statementTransaction(ctx, s.DB, func(tx *sql.Tx) (struct{}, error) {
		var done struct{}
		key := sql.Named("user_id", user)
		var locked int64
		err := tx.QueryRowContext(ctx, lock, key).Scan(&locked)
		if errors.Is(err, sql.ErrNoRows) {
			return done, nil
		}
		if err != nil {
			return done, errSessionStore
		}
		restored, err := postTxExecute(ctx, tx, banExpirySQL["restore"], key)
		if err != nil || restored == 0 {
			return done, err
		}
		expired, err := postTxExecute(ctx, tx, banExpirySQL["expire"], key)
		if err != nil || expired < 1 {
			return done, errSessionStore
		}
		return done, nil
	})
	return err
}

// RunBanExpiry reconciles a bounded batch on each tick. Contended rows are retried on later ticks.
func (s OracleSessions) RunBanExpiry(ctx context.Context) {
	ticker := time.NewTicker(time.Duration(banExpiry.IntervalSeconds) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			batch, cancel := context.WithTimeout(ctx, 25*time.Second)
			err := s.sweepExpiredBans(batch)
			cancel()
			if err != nil && ctx.Err() == nil {
				log.Print("moderation ban expiry sweep incomplete")
			}
		}
	}
}

func (s OracleSessions) sweepExpiredBans(ctx context.Context) error {
	users, err := s.banExpiryCandidates(ctx)
	if err != nil {
		return err
	}
	var failed error
	for _, user := range users {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := s.restoreBan(ctx, user, banExpirySQL["lock"]+" SKIP LOCKED"); err != nil {
			failed = err
		}
	}
	return failed
}

func (s OracleSessions) banExpiryCandidates(ctx context.Context) ([]int64, error) {
	rows, err := s.DB.QueryContext(ctx, banExpirySQL["candidates"])
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	var users []int64
	for rows.Next() {
		var user int64
		if err := rows.Scan(&user); err != nil {
			return nil, errSessionStore
		}
		users = append(users, user)
	}
	return users, rows.Err()
}
