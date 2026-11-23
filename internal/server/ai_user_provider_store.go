package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type userProviderReader interface {
	readUserProvider(context.Context, int64) (*userProviderRecord, error)
}

type userProviderStore interface {
	userProviderReader
	saveUserProvider(context.Context, int64, userProviderSettings, userProviderInput) (userProviderRecord, error)
	deleteUserProvider(context.Context, int64) error
}

func verifyUserProviderSchema(ctx context.Context, conn *sql.Conn) error {
	var catalog schemaCatalog
	if json.Unmarshal(contracts.AIUserProviderSchemaCatalog, &catalog) != nil || validateFeatureSchema(ctx, conn, catalog, "ai-user-provider") != nil {
		return errUserProviderUnavailable
	}
	return nil
}

func readUserProviderRow(ctx context.Context, db publicProfileQueryer, user int64) (*userProviderRecord, error) {
	var record userProviderRecord
	var enabled int64
	err := db.QueryRowContext(ctx, userProviderContract.SQL["read"], sql.Named("user_id", user)).Scan(&record.Preset, &record.BaseURL,
		&record.Model, &record.SecretBox, &enabled, &record.Revision)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil || (record.Preset != "default" && record.Preset != "provided") || record.BaseURL == "" ||
		!validUserProviderModel(record.Model) || record.Revision < 1 || record.Revision > maxUserProviderRevision ||
		(enabled != 0 && enabled != 1) {
		return nil, errUserProviderUnavailable
	}
	record.Enabled = enabled == 1
	return &record, nil
}

func (s OracleSessions) readUserProvider(ctx context.Context, user int64) (record *userProviderRecord, err error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errUserProviderUnavailable
	}
	defer func() {
		if conn.Close() != nil {
			record, err = nil, errUserProviderUnavailable
		}
	}()
	if err := verifyUserProviderSchema(ctx, conn); err != nil {
		return nil, err
	}
	return readUserProviderRow(ctx, conn, user)
}

func (s OracleSessions) saveUserProvider(ctx context.Context, user int64, settings userProviderSettings, input userProviderInput) (userProviderRecord, error) {
	return s.saveUserProviderOperation(ctx, user, settings, input, verifyUserProviderSchema)
}

func (s OracleSessions) saveUserProviderOperation(ctx context.Context, user int64, settings userProviderSettings, input userProviderInput, verify func(context.Context, *sql.Conn) error) (userProviderRecord, error) {
	var result userProviderRecord
	err := s.editUserProvider(ctx, user, verify, func(tx *sql.Tx) error {
		previous, err := readUserProviderRow(ctx, tx, user)
		if err != nil {
			return err
		}
		record, err := settings.update(user, input, previous)
		if err != nil {
			return err
		}
		enabled := 0
		if record.Enabled {
			enabled = 1
		}
		count, err := postTxExecute(ctx, tx, userProviderContract.SQL["save"], sql.Named("user_id", user), sql.Named("preset_id", record.Preset),
			sql.Named("base_url", record.BaseURL), sql.Named("model_name", record.Model), sql.Named("secret_box", record.SecretBox),
			sql.Named("enabled", enabled), sql.Named("revision", record.Revision))
		if err != nil || count != 1 {
			return errUserProviderUnavailable
		}
		result = record
		return nil
	})
	if err != nil {
		return userProviderRecord{}, err
	}
	return result, nil
}

func (s OracleSessions) deleteUserProvider(ctx context.Context, user int64) error {
	return s.editUserProvider(ctx, user, verifyUserProviderSchema, func(tx *sql.Tx) error {
		count, err := postTxExecute(ctx, tx, userProviderContract.SQL["delete"], sql.Named("user_id", user))
		if err != nil || count < 0 || count > 1 {
			return errUserProviderUnavailable
		}
		return nil
	})
}

// Credentials are bound and updated using a single connection and an active-owner row lock.
func (s OracleSessions) editUserProvider(ctx context.Context, user int64, verify func(context.Context, *sql.Conn) error, edit func(*sql.Tx) error) (err error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return errUserProviderUnavailable
	}
	defer func() {
		if conn.Close() != nil {
			err = errUserProviderUnavailable
		}
	}()
	if err := verify(ctx, conn); err != nil {
		return err
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return errUserProviderUnavailable
	}
	defer tx.Rollback()
	var owner int64
	if err := tx.QueryRowContext(ctx, userProviderContract.SQL["lock_user"], sql.Named("user_id", user)).Scan(&owner); err != nil || owner != user {
		return errUserProviderUnavailable
	}
	if err := edit(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return errUserProviderUnavailable
	}
	return nil
}
