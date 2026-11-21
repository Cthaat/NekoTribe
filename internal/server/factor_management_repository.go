package server

import (
	"context"
	"database/sql"
	"errors"
)

const factorSetupSQL = `MERGE INTO n_user_two_factor_secrets target USING (SELECT :user_id AS user_id FROM dual) src ON (target.user_id = src.user_id) WHEN MATCHED THEN UPDATE SET secret_encrypted = :secret_encrypted, secret_iv = :secret_iv, secret_auth_tag = :secret_auth_tag, confirmed_at = NULL, enabled_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE target.enabled_at IS NULL WHEN NOT MATCHED THEN INSERT (user_id, secret_encrypted, secret_iv, secret_auth_tag) VALUES (:user_id, :secret_encrypted, :secret_iv, :secret_auth_tag)`
const factorConfirmSQL = `UPDATE n_user_two_factor_secrets SET confirmed_at = CURRENT_TIMESTAMP, enabled_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND secret_encrypted = :old_encrypted AND secret_iv = :old_iv AND secret_auth_tag = :old_tag AND enabled_at IS NULL`
const factorDisableSQL = `UPDATE n_user_two_factor_secrets SET enabled_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id AND secret_encrypted = :old_encrypted AND secret_iv = :old_iv AND secret_auth_tag = :old_tag AND enabled_at IS NOT NULL`
const factorClearCodesSQL = `DELETE FROM n_user_two_factor_recovery_codes WHERE user_id = :user_id`
const factorClearDevicesSQL = `DELETE FROM n_user_two_factor_trusted_devices WHERE user_id = :user_id`
const factorSettingsSQL = `MERGE INTO n_user_settings target USING (SELECT :user_id AS user_id FROM dual) src ON (target.user_id = src.user_id) WHEN MATCHED THEN UPDATE SET two_factor_enabled = :enabled, updated_at = CURRENT_TIMESTAMP WHEN NOT MATCHED THEN INSERT (user_id, two_factor_enabled) VALUES (:user_id, :enabled)`
const factorRecoverySQL = `INSERT INTO n_user_two_factor_recovery_codes (recovery_code_id, user_id, code_hash) VALUES (seq_2fa_recovery_code_id.NEXTVAL, :user_id, :code_hash)`

func (s OracleSessions) ApplyFactorMutation(ctx context.Context, user int64, m FactorMutation) (outcome int, err error) {
	if m.Action != "setup" && m.Action != "confirm" && m.Action != "disable" {
		return 0, errSessionStore
	}
	if m.Action == "confirm" && len(m.RecoveryHashes) != 10 {
		return 0, errSessionStore
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return 0, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			outcome, err = 0, errSessionStore
		}
	}()
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return 0, errSessionStore
	}
	committed := false
	defer func() {
		if !committed {
			if e := tx.Rollback(); e != nil && !errors.Is(e, sql.ErrTxDone) {
				outcome, err = 0, errSessionStore
			}
		}
	}()
	exec := func(query string, args ...interface{}) (int64, error) {
		r, e := tx.ExecContext(ctx, query, args...)
		if e != nil {
			return 0, errSessionStore
		}
		n, e := r.RowsAffected()
		if e != nil || n < 0 {
			return 0, errSessionStore
		}
		return n, nil
	}
	query := factorSetupSQL
	args := []interface{}{sql.Named("user_id", user)}
	if m.Action == "setup" {
		args = append(args, sql.Named("secret_encrypted", m.New.Encrypted), sql.Named("secret_iv", m.New.IV), sql.Named("secret_auth_tag", m.New.Tag))
	} else {
		if m.Action == "confirm" {
			query = factorConfirmSQL
		} else {
			query = factorDisableSQL
		}
		args = append(args, sql.Named("old_encrypted", m.Expected.Encrypted), sql.Named("old_iv", m.Expected.IV), sql.Named("old_tag", m.Expected.Tag))
	}
	n, e := exec(query, args...)
	if e != nil || n > 1 {
		return 0, errSessionStore
	}
	if n == 0 {
		return factorChanged, nil
	}
	if m.RecoveryID != 0 || m.UsesRecoveryCode {
		n, e = exec(consumeRecoverySQL, sql.Named("recovery_code_id", m.RecoveryID), sql.Named("user_id", user))
		if e != nil || n > 1 {
			return 0, errSessionStore
		}
		if n == 0 {
			return factorRecoveryUsed, nil
		}
	}
	if _, e = exec(factorClearCodesSQL, sql.Named("user_id", user)); e != nil {
		return 0, errSessionStore
	}
	if m.Action == "confirm" {
		for _, hash := range m.RecoveryHashes {
			n, e = exec(factorRecoverySQL, sql.Named("user_id", user), sql.Named("code_hash", hash))
			if e != nil || n != 1 {
				return 0, errSessionStore
			}
		}
	} else {
		if _, e = exec(factorClearDevicesSQL, sql.Named("user_id", user)); e != nil {
			return 0, errSessionStore
		}
	}
	query = factorSettingsSQL
	enabled := 0
	if m.Action == "confirm" {
		enabled = 1
	}
	args = []interface{}{sql.Named("user_id", user), sql.Named("enabled", enabled)}
	if m.Action == "disable" {
		query = `UPDATE n_user_settings SET two_factor_enabled = 0, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id`
		args = args[:1]
	}
	n, e = exec(query, args...)
	if e != nil || (m.Action != "disable" && n != 1) {
		return 0, errSessionStore
	}
	if tx.Commit() != nil {
		return 0, errSessionStore
	}
	committed = true
	return factorApplied, nil
}
