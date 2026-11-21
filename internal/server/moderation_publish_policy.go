package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

var publishPolicy = func() struct {
	Message string
	SQL     map[string]string
} {
	var spec struct {
		Message string
		SQL     map[string]string
	}
	if err := json.Unmarshal(contracts.ModerationPublishPolicyContract, &spec); err != nil {
		panic("invalid moderation publish policy")
	}
	return spec
}()

var errPublishForbidden = errors.New("moderation publishing denied")

// The target account lock is shared with the restriction and account-state writers.
func checkPublishAccess(ctx context.Context, tx *sql.Tx, user int64) error {
	key := sql.Named("user_id", user)
	var id int64
	err := tx.QueryRowContext(ctx, publishPolicy.SQL["lock"], key).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return errPublishForbidden
	}
	if err != nil {
		return errSessionStore
	}
	var allowed int64
	if err := tx.QueryRowContext(ctx, publishPolicy.SQL["allowed"], key).Scan(&allowed); err != nil {
		return errSessionStore
	}
	if allowed != 1 {
		return errPublishForbidden
	}
	return nil
}
