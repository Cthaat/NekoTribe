package server

import (
	"context"
	"database/sql"
	"errors"
)

const insertChallengeSQL = `INSERT INTO n_auth_two_factor_challenges (challenge_id,user_id,remember_me,device_info,device_fingerprint,ip_address,user_agent,expires_at) VALUES (:challenge_id,:user_id,:remember_me,:device_info,:device_fingerprint,:ip_address,:user_agent,:expires_at)`
const challengeLookupSQL = `SELECT c.challenge_id,c.user_id,c.remember_me,c.device_info,c.device_fingerprint,c.ip_address,c.user_agent,u.username,u.password_hash FROM n_auth_two_factor_challenges c JOIN n_users u ON u.user_id=c.user_id WHERE c.challenge_id=:challenge_id AND c.expires_at>CURRENT_TIMESTAMP AND c.consumed_at IS NULL AND u.is_active=1 AND u.status='active'`
const factorSecretSQL = `SELECT secret_encrypted,secret_iv,secret_auth_tag,enabled_at FROM n_user_two_factor_secrets WHERE user_id=:user_id`
const recoveryCodesSQL = `SELECT recovery_code_id,code_hash FROM n_user_two_factor_recovery_codes WHERE user_id=:user_id AND used_at IS NULL ORDER BY created_at ASC`
const consumeRecoverySQL = `UPDATE n_user_two_factor_recovery_codes SET used_at=CURRENT_TIMESTAMP WHERE recovery_code_id=:recovery_code_id AND user_id=:user_id AND used_at IS NULL`
const consumeChallengeSQL = `UPDATE n_auth_two_factor_challenges SET consumed_at=CURRENT_TIMESTAMP WHERE challenge_id=:challenge_id AND user_id=:user_id AND consumed_at IS NULL AND expires_at>CURRENT_TIMESTAMP`
const insertTrustedDeviceSQL = `INSERT INTO n_user_two_factor_trusted_devices
(trusted_device_id,user_id,device_fingerprint,device_info,ip_address,user_agent,expires_at)
VALUES (:trusted_device_id,:user_id,:device_fingerprint,:device_info,:ip_address,:user_agent,:expires_at)`
const trustedDeviceSequenceSQL = `SELECT seq_2fa_trusted_device_id.NEXTVAL FROM dual`
const lockLoginFactorSQL = `SELECT user_id FROM n_user_two_factor_secrets WHERE user_id = :user_id FOR UPDATE`
const currentLoginFactorSQL = `SELECT user_id FROM n_user_two_factor_secrets
WHERE user_id=:user_id AND enabled_at IS NOT NULL
AND secret_encrypted=:old_encrypted AND secret_iv=:old_iv AND secret_auth_tag=:old_tag`

var errFactorCompletionUnavailable = errors.New("factor completion unavailable")

func (s OracleSessions) CreateLoginChallenge(ctx context.Context, c LoginChallenge) error {
	remember := 0
	if c.Remember {
		remember = 1
	}
	return s.executeLoginWrite(ctx, c.UserID, c.verifiedPasswordHash, insertChallengeSQL, sql.Named("challenge_id", c.ID), sql.Named("user_id", c.UserID), sql.Named("remember_me", remember), sql.Named("device_info", c.DeviceInfo), sql.Named("device_fingerprint", c.Fingerprint), sql.Named("ip_address", c.IPAddress), sql.Named("user_agent", c.UserAgent), sql.Named("expires_at", c.ExpiresAt))
}
func (s OracleSessions) FindLoginChallenge(ctx context.Context, id string) (LoginChallenge, bool, error) {
	var c LoginChallenge
	var remember int64
	var info, fp, ip, agent sql.NullString
	err := s.DB.QueryRowContext(ctx, challengeLookupSQL, sql.Named("challenge_id", id)).Scan(&c.ID, &c.UserID, &remember, &info, &fp, &ip, &agent, &c.Username, &c.verifiedPasswordHash)
	if errors.Is(err, sql.ErrNoRows) {
		return LoginChallenge{}, false, nil
	}
	if err != nil {
		return LoginChallenge{}, false, errSessionStore
	}
	c.Remember = remember != 0
	c.DeviceInfo = info.String
	c.Fingerprint = fp.String
	c.IPAddress = ip.String
	c.UserAgent = agent.String
	return c, true, nil
}
func (s OracleSessions) FindFactorSecret(ctx context.Context, id int64) (FactorSecret, bool, error) {
	var f FactorSecret
	var enabled sql.NullTime
	err := s.DB.QueryRowContext(ctx, factorSecretSQL, sql.Named("user_id", id)).Scan(&f.Encrypted, &f.IV, &f.Tag, &enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return FactorSecret{}, false, nil
	}
	if err != nil {
		return FactorSecret{}, false, errSessionStore
	}
	f.Enabled = enabled.Valid
	return f, true, nil
}
func (s OracleSessions) FindRecoveryCodes(ctx context.Context, id int64) ([]RecoveryCode, error) {
	rows, err := s.DB.QueryContext(ctx, recoveryCodesSQL, sql.Named("user_id", id))
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	result := []RecoveryCode{}
	for rows.Next() {
		var c RecoveryCode
		if rows.Scan(&c.ID, &c.Hash) != nil {
			return nil, errSessionStore
		}
		result = append(result, c)
	}
	if rows.Err() != nil {
		return nil, errSessionStore
	}
	return result, nil
}
func writeFactorCompletion(ctx context.Context, tx *sql.Tx, userID int64, completion factorCompletion) error {
	user := sql.Named("user_id", userID)
	var current int64
	if err := tx.QueryRowContext(ctx, lockLoginFactorSQL, user).Scan(&current); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return errFactorCompletionUnavailable
		}
		return errSessionStore
	}
	secret := completion.verifiedSecret
	if err := tx.QueryRowContext(ctx, currentLoginFactorSQL, user, sql.Named("old_encrypted", secret.Encrypted),
		sql.Named("old_iv", secret.IV), sql.Named("old_tag", secret.Tag)).Scan(&current); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return errFactorCompletionUnavailable
		}
		return errSessionStore
	}
	if err := consumeFactorCredential(ctx, tx, consumeChallengeSQL, sql.Named("challenge_id", completion.challenge.ID), user); err != nil {
		return err
	}
	if completion.recoveryCodeID != nil {
		if err := consumeFactorCredential(ctx, tx, consumeRecoverySQL, sql.Named("recovery_code_id", *completion.recoveryCodeID), user); err != nil {
			return err
		}
	}
	if completion.trustedKey == "" {
		return nil
	}
	var id int64
	if err := tx.QueryRowContext(ctx, trustedDeviceSequenceSQL).Scan(&id); err != nil {
		return errSessionStore
	}
	return execLoginWrite(ctx, tx, insertTrustedDeviceSQL, sql.Named("trusted_device_id", id),
		user, sql.Named("device_fingerprint", completion.trustedKey), sql.Named("device_info", completion.challenge.DeviceInfo),
		sql.Named("ip_address", completion.challenge.IPAddress), sql.Named("user_agent", completion.challenge.UserAgent),
		sql.Named("expires_at", completion.trustedExpiry))
}

func consumeFactorCredential(ctx context.Context, tx *sql.Tx, statement string, binds ...any) error {
	result, err := tx.ExecContext(ctx, statement, binds...)
	if err != nil {
		return errSessionStore
	}
	count, err := result.RowsAffected()
	if err != nil || count > 1 {
		return errSessionStore
	}
	if count == 0 {
		return errFactorCompletionUnavailable
	}
	return nil
}
