package server

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

const trustedDeviceSQL = `SELECT trusted_device_id FROM n_user_two_factor_trusted_devices WHERE user_id=:user_id AND device_fingerprint=:device_fingerprint AND expires_at>CURRENT_TIMESTAMP AND revoked_at IS NULL FETCH FIRST 1 ROWS ONLY`
const updateTrustedSQL = `UPDATE n_user_two_factor_trusted_devices SET last_used_at=CURRENT_TIMESTAMP,device_info=:device_info,ip_address=:ip_address,user_agent=:user_agent WHERE trusted_device_id=:trusted_device_id`
const insertChallengeSQL = `INSERT INTO n_auth_two_factor_challenges (challenge_id,user_id,remember_me,device_info,device_fingerprint,ip_address,user_agent,expires_at) VALUES (:challenge_id,:user_id,:remember_me,:device_info,:device_fingerprint,:ip_address,:user_agent,:expires_at)`
const challengeLookupSQL = `SELECT c.challenge_id,c.user_id,c.remember_me,c.device_info,c.device_fingerprint,c.ip_address,c.user_agent,u.username FROM n_auth_two_factor_challenges c JOIN n_users u ON u.user_id=c.user_id WHERE c.challenge_id=:challenge_id AND c.expires_at>CURRENT_TIMESTAMP AND c.consumed_at IS NULL AND u.is_active=1 AND u.status='active'`
const factorSecretSQL = `SELECT secret_encrypted,secret_iv,secret_auth_tag,enabled_at FROM n_user_two_factor_secrets WHERE user_id=:user_id`
const recoveryCodesSQL = `SELECT recovery_code_id,code_hash FROM n_user_two_factor_recovery_codes WHERE user_id=:user_id AND used_at IS NULL ORDER BY created_at ASC`
const consumeRecoverySQL = `UPDATE n_user_two_factor_recovery_codes SET used_at=CURRENT_TIMESTAMP WHERE recovery_code_id=:recovery_code_id AND used_at IS NULL`
const consumeChallengeSQL = `UPDATE n_auth_two_factor_challenges SET consumed_at=CURRENT_TIMESTAMP WHERE challenge_id=:challenge_id AND consumed_at IS NULL AND expires_at>CURRENT_TIMESTAMP`
const trustedMergeSQL = `MERGE INTO n_user_two_factor_trusted_devices target USING (SELECT :user_id AS user_id,:device_fingerprint AS device_fingerprint FROM dual) src ON (target.user_id=src.user_id AND target.device_fingerprint=src.device_fingerprint) WHEN MATCHED THEN UPDATE SET device_info=:device_info,ip_address=:ip_address,user_agent=:user_agent,expires_at=:expires_at,revoked_at=NULL,last_used_at=CURRENT_TIMESTAMP WHEN NOT MATCHED THEN INSERT (trusted_device_id,user_id,device_fingerprint,device_info,ip_address,user_agent,expires_at) VALUES (:trusted_device_id,:user_id,:device_fingerprint,:device_info,:ip_address,:user_agent,:expires_at)`

var twoFactorReadinessSQL = []string{
	`SELECT user_id,secret_encrypted,secret_iv,secret_auth_tag,confirmed_at,enabled_at,created_at,updated_at FROM n_user_two_factor_secrets WHERE 1=0`,
	`SELECT recovery_code_id,user_id,code_hash,used_at,created_at FROM n_user_two_factor_recovery_codes WHERE 1=0`,
	`SELECT trusted_device_id,user_id,device_fingerprint,device_info,ip_address,user_agent,expires_at,revoked_at,created_at,last_used_at FROM n_user_two_factor_trusted_devices WHERE 1=0`,
	`SELECT challenge_id,user_id,remember_me,device_info,device_fingerprint,ip_address,user_agent,expires_at,consumed_at,created_at FROM n_auth_two_factor_challenges WHERE 1=0`,
}

// Read-only availability check; full migration ledger/constraint verification remains pending.
func (s OracleSessions) CheckTwoFactorSchema(ctx context.Context) error {
	for _, q := range twoFactorReadinessSQL {
		rows, err := s.DB.QueryContext(ctx, q)
		if err != nil {
			return errSessionStore
		}
		if rows.Close() != nil {
			return errSessionStore
		}
	}
	return nil
}

func (s OracleSessions) UseTrustedDevice(ctx context.Context, user int64, fingerprint, info, ip, agent string) (bool, error) {
	var id int64
	err := s.DB.QueryRowContext(ctx, trustedDeviceSQL, sql.Named("user_id", user), sql.Named("device_fingerprint", fingerprint)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, errSessionStore
	}
	_, err = s.execute(ctx, updateTrustedSQL, sql.Named("device_info", info), sql.Named("ip_address", ip), sql.Named("user_agent", agent), sql.Named("trusted_device_id", id))
	if err != nil {
		return false, errSessionStore
	}
	return true, nil
}
func (s OracleSessions) CreateLoginChallenge(ctx context.Context, c LoginChallenge) error {
	remember := 0
	if c.Remember {
		remember = 1
	}
	n, err := s.execute(ctx, insertChallengeSQL, sql.Named("challenge_id", c.ID), sql.Named("user_id", c.UserID), sql.Named("remember_me", remember), sql.Named("device_info", c.DeviceInfo), sql.Named("device_fingerprint", c.Fingerprint), sql.Named("ip_address", c.IPAddress), sql.Named("user_agent", c.UserAgent), sql.Named("expires_at", c.ExpiresAt))
	if err != nil || n != 1 {
		return errSessionStore
	}
	return nil
}
func (s OracleSessions) FindLoginChallenge(ctx context.Context, id string) (LoginChallenge, bool, error) {
	var c LoginChallenge
	var remember int64
	var info, fp, ip, agent sql.NullString
	err := s.DB.QueryRowContext(ctx, challengeLookupSQL, sql.Named("challenge_id", id)).Scan(&c.ID, &c.UserID, &remember, &info, &fp, &ip, &agent, &c.Username)
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
func (s OracleSessions) ConsumeRecoveryCode(ctx context.Context, id int64) (bool, error) {
	n, err := s.execute(ctx, consumeRecoverySQL, sql.Named("recovery_code_id", id))
	return n == 1, err
}
func (s OracleSessions) ConsumeLoginChallenge(ctx context.Context, id string) (bool, error) {
	n, err := s.execute(ctx, consumeChallengeSQL, sql.Named("challenge_id", id))
	return n == 1, err
}
func (s OracleSessions) TrustLoginDevice(ctx context.Context, c LoginChallenge, expires time.Time) error {
	var id int64
	if err := s.DB.QueryRowContext(ctx, `SELECT seq_2fa_trusted_device_id.NEXTVAL FROM dual`).Scan(&id); err != nil {
		return errSessionStore
	}
	_, err := s.execute(ctx, trustedMergeSQL, sql.Named("user_id", c.UserID), sql.Named("device_fingerprint", c.Fingerprint), sql.Named("device_info", c.DeviceInfo), sql.Named("ip_address", c.IPAddress), sql.Named("user_agent", c.UserAgent), sql.Named("expires_at", expires), sql.Named("trusted_device_id", id))
	return err
}
