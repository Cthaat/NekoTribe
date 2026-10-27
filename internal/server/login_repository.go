package server

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

const loginLookupSQL = `SELECT user_id, username, password_hash, status, is_active FROM n_users WHERE email = :account OR username = :account FETCH FIRST 1 ROWS ONLY`
const twoFactorStatusSQL = `SELECT NVL(us.two_factor_enabled, 0), tf.enabled_at FROM n_users u LEFT JOIN n_user_settings us ON us.user_id = u.user_id LEFT JOIN n_user_two_factor_secrets tf ON tf.user_id = u.user_id WHERE u.user_id = :user_id`
const insertLoginSessionSQL = `INSERT INTO n_auth_sessions (session_id,user_id,access_jti,refresh_token_hash,device_info,device_fingerprint,ip_address,user_agent,access_token_expires_at,refresh_token_expires_at) VALUES (:session_id,:user_id,:access_jti,:refresh_token_hash,:device_info,:device_fingerprint,:ip_address,:user_agent,:access_token_expires_at,:refresh_token_expires_at)`
const updateLastLoginSQL = `UPDATE n_users SET last_login_at = CURRENT_TIMESTAMP WHERE user_id = :user_id`
const selfProfileSQL = `SELECT user_id,email,username,avatar_url,display_name,bio,location,website,phone,TO_CHAR(birth_date,'YYYY-MM-DD'),email_verified_at,is_verified,is_active,status,followers_count,following_count,posts_count,likes_count,(SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL),created_at,updated_at,fn_get_user_relationship(:viewer_id,u.user_id) FROM v_user_profile_self u WHERE u.user_id=:user_id`

func (s OracleSessions) LookupLogin(ctx context.Context, account string) (LoginAccount, bool, error) {
	var result LoginAccount
	var active int64
	err := s.DB.QueryRowContext(ctx, loginLookupSQL, sql.Named("account", account)).Scan(&result.UserID, &result.Username, &result.PasswordHash, &result.Status, &active)
	if errors.Is(err, sql.ErrNoRows) {
		return LoginAccount{}, false, nil
	}
	if err != nil {
		return LoginAccount{}, false, errSessionStore
	}
	result.Active = active == 1
	return result, true, nil
}
func (s OracleSessions) TwoFactorEnabled(ctx context.Context, user int64) (bool, error) {
	var enabled int64
	var at sql.NullTime
	err := s.DB.QueryRowContext(ctx, twoFactorStatusSQL, sql.Named("user_id", user)).Scan(&enabled, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return false, errSessionStore
	}
	if err != nil {
		return false, errSessionStore
	}
	return enabled != 0 && at.Valid, nil
}
func (s OracleSessions) InsertLoginSession(ctx context.Context, v LoginSession) error {
	n, err := s.execute(ctx, insertLoginSessionSQL, sql.Named("session_id", v.SessionID), sql.Named("user_id", v.UserID), sql.Named("access_jti", v.AccessJTI), sql.Named("refresh_token_hash", v.RefreshHash), sql.Named("device_info", v.DeviceInfo), sql.Named("device_fingerprint", v.DeviceFingerprint), sql.Named("ip_address", v.IPAddress), sql.Named("user_agent", v.UserAgent), sql.Named("access_token_expires_at", v.AccessExpiresAt), sql.Named("refresh_token_expires_at", v.RefreshExpiresAt))
	if err != nil || n != 1 {
		return errSessionStore
	}
	return nil
}
func (s OracleSessions) UpdateLastLogin(ctx context.Context, user int64) error {
	n, err := s.execute(ctx, updateLastLoginSQL, sql.Named("user_id", user))
	if err != nil || n != 1 {
		return errSessionStore
	}
	return nil
}
func (s OracleSessions) SelfProfile(ctx context.Context, user int64) (SelfUser, bool, error) {
	var v SelfUser
	var email, avatar, display, bio, location, website, phone, birth, status, relation sql.NullString
	var verifiedAt, lastSeen, created, updated sql.NullTime
	var verified, active, followers, following, posts, likes sql.NullInt64
	err := s.DB.QueryRowContext(ctx, selfProfileSQL, sql.Named("viewer_id", user), sql.Named("user_id", user)).Scan(&v.UserID, &email, &v.Username, &avatar, &display, &bio, &location, &website, &phone, &birth, &verifiedAt, &verified, &active, &status, &followers, &following, &posts, &likes, &lastSeen, &created, &updated, &relation)
	if errors.Is(err, sql.ErrNoRows) {
		return SelfUser{}, false, nil
	}
	if err != nil {
		return SelfUser{}, false, errSessionStore
	}
	v.Email = email.String
	v.AvatarURL = strings.TrimSpace(avatar.String)
	if v.AvatarURL == "" || v.AvatarURL == "/default-avatar.png" || v.AvatarURL == "default-avatar.png" {
		v.AvatarURL = "/storage/default-avatar.png"
	}
	v.DisplayName = display.String
	v.Bio = bio.String
	v.Location = location.String
	v.Website = website.String
	v.Phone = phone.String
	v.Status = status.String
	if birth.Valid && birth.String != "" {
		v.BirthDate = &birth.String
	}
	v.EmailVerifiedAt = profileDate(verifiedAt)
	v.LastSeenAt = profileDate(lastSeen)
	v.IsVerified = verified.Int64
	v.IsActive = active.Int64
	v.FollowersCount = followers.Int64
	v.FollowingCount = following.Int64
	v.PostsCount = posts.Int64
	v.LikesCount = likes.Int64
	v.OnlineStatus = "online"
	if created.Valid {
		v.CreatedAt = created.Time.UTC().Format("2006-01-02T15:04:05.000Z")
	}
	if updated.Valid {
		v.UpdatedAt = updated.Time.UTC().Format("2006-01-02T15:04:05.000Z")
	}
	rel := relation.String
	if rel == "" {
		rel = "none"
	}
	v.Relationship = SelfRelationship{IsSelf: rel == "self", IsFollowing: rel == "following" || rel == "mutual_follow", IsBlocked: rel == "blocked_by", IsBlocking: rel == "blocking", Relation: rel}
	return v, true, nil
}
func profileDate(value sql.NullTime) *string {
	if !value.Valid {
		return nil
	}
	text := value.Time.UTC().Format("2006-01-02T15:04:05.000Z")
	return &text
}
