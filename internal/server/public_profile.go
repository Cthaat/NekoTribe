package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type PublicUser struct {
	UserID         int64            `json:"user_id"`
	Username       string           `json:"username"`
	DisplayName    string           `json:"display_name"`
	AvatarURL      string           `json:"avatar_url"`
	Bio            string           `json:"bio"`
	Location       string           `json:"location"`
	Website        string           `json:"website"`
	IsVerified     int64            `json:"is_verified"`
	FollowersCount int64            `json:"followers_count"`
	FollowingCount int64            `json:"following_count"`
	PostsCount     int64            `json:"posts_count"`
	LikesCount     int64            `json:"likes_count"`
	Relationship   SelfRelationship `json:"relationship"`
	OnlineStatus   string           `json:"online_status"`
	LastSeenAt     *string          `json:"last_seen_at"`
}

const publicProfileSQL = `SELECT u.user_id,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,CASE WHEN NVL(us.show_online_status,1)=0 THEN 'hidden' WHEN EXISTS (SELECT 1 FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL AND s.last_accessed_at >= CURRENT_TIMESTAMP - NUMTODSINTERVAL(90,'SECOND')) THEN 'online' ELSE 'offline' END AS online_status,CASE WHEN NVL(us.show_online_status,1)=0 THEN NULL ELSE (SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL) END AS last_seen_at,fn_get_user_relationship(:viewer_id,u.user_id) AS relation FROM v_user_profile_public u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id AND u.is_active=1`

func (s OracleSessions) PublicProfile(ctx context.Context, viewer, target int64) (PublicUser, bool, error) {
	var v PublicUser
	var username, avatar, display, bio, location, website, status, relation sql.NullString
	var verified, followers, following, posts, likes sql.NullInt64
	var seen sql.NullTime
	err := s.DB.QueryRowContext(ctx, publicProfileSQL, sql.Named("viewer_id", viewer), sql.Named("user_id", target)).Scan(&v.UserID, &username, &avatar, &display, &bio, &location, &website, &verified, &followers, &following, &posts, &likes, &status, &seen, &relation)
	if errors.Is(err, sql.ErrNoRows) {
		return PublicUser{}, false, nil
	}
	if err != nil {
		return PublicUser{}, false, errSessionStore
	}
	v.Username = username.String
	v.AvatarURL = avatar.String
	v.DisplayName = display.String
	v.Bio = bio.String
	v.Location = location.String
	v.Website = website.String
	v.IsVerified = verified.Int64
	v.FollowersCount = followers.Int64
	v.FollowingCount = following.Int64
	v.PostsCount = posts.Int64
	v.LikesCount = likes.Int64
	rel := relation.String
	if !relation.Valid {
		rel = "none"
	}
	v.Relationship = SelfRelationship{IsSelf: rel == "self", IsFollowing: rel == "following" || rel == "mutual_follow", IsBlocked: rel == "blocked_by", IsBlocking: rel == "blocking", Relation: rel}
	v.OnlineStatus = "offline"
	if status.String == "online" || status.String == "hidden" {
		v.OnlineStatus = status.String
	}
	if v.OnlineStatus != "hidden" {
		v.LastSeenAt = profileDate(seen)
	}
	return v, true, nil
}

type publicProfileStore interface {
	PublicProfile(context.Context, int64, int64) (PublicUser, bool, error)
}

var publicID = regexp.MustCompile(`^[1-9][0-9]*$`)

func getPublicProfile(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	w.Header().Set("Cache-Control", "private, no-store")
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	if n, e := repository.Touch(r.Context(), claims); e != nil || n != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	raw, err = url.PathUnescape(raw)
	if err != nil || !publicID.MatchString(raw) {
		respond(w, 400, 40001, "id 参数错误", nil)
		return
	}
	target, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || target > 9007199254740991 {
		respond(w, 400, 40001, "id 参数错误", nil)
		return
	}
	store, ok := repository.(publicProfileStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	profile, found, err := store.PublicProfile(r.Context(), claims.UserID, target)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	profile.AvatarURL, err = normalizeAvatarURL(config.Storage, profile.AvatarURL)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "success", profile)
}
func publicProfileSegment(path string) (string, bool) {
	const prefix = "/api/v2/users/"
	if !strings.HasPrefix(path, prefix) {
		return "", false
	}
	id := strings.TrimPrefix(path, prefix)
	return id, id != "" && !strings.Contains(id, "/")
}
