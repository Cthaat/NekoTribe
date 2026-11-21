package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/url"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupLookup struct {
	id   int64
	slug string
}

type groupDetail struct {
	ID             int64                 `json:"group_id"`
	Name           string                `json:"name"`
	Slug           string                `json:"slug"`
	Description    string                `json:"description"`
	AvatarURL      *string               `json:"avatar_url"`
	CoverURL       *string               `json:"cover_url"`
	Category       *string               `json:"category"`
	Tags           []string              `json:"tags"`
	Owner          PublicUser            `json:"owner"`
	Privacy        string                `json:"privacy"`
	PrivacyDesc    string                `json:"privacy_desc"`
	JoinApproval   bool                  `json:"join_approval"`
	PostPermission string                `json:"post_permission"`
	MemberCount    int64                 `json:"member_count"`
	PostCount      int64                 `json:"post_count"`
	Active         int64                 `json:"is_active"`
	Membership     groupDetailMembership `json:"membership"`
	CreatedAt      string                `json:"created_at"`
	UpdatedAt      string                `json:"updated_at"`
}

type groupDetailMembership struct {
	IsMember bool    `json:"is_member"`
	Role     *string `json:"role"`
	Status   *string `json:"status"`
	JoinedAt *string `json:"joined_at"`
}

type groupDetailStore interface {
	GroupDetail(context.Context, int64, groupLookup, StorageURLPolicy) (groupDetail, error)
}

var errGroupDetailMissing = errors.New("group not found")
var errGroupOwnerMissing = errors.New("group owner not found")

const groupColumns = `SELECT g.group_id,g.group_name,g.slug,g.description,g.group_avatar_url,g.cover_url,g.category,g.owner_id,
g.privacy,g.privacy_desc,g.join_approval,g.post_permission,g.member_count,g.post_count,g.is_active,
g.created_at,g.updated_at,m.user_id AS member_id,m.role AS member_role,m.status AS member_status,m.joined_at`
const groupFrom = `FROM v_group_details g LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:viewer_id`
const groupDetailSQL = groupColumns + "\n" + groupFrom + " WHERE g.is_deleted=0 AND "
const groupTagsSQL = `SELECT tag FROM n_group_tags WHERE group_id=:group_id ORDER BY created_at ASC,tag_lower ASC`

func (s OracleSessions) GroupDetail(ctx context.Context, viewer int64, key groupLookup, storage StorageURLPolicy) (groupDetail, error) {
	return readGroupDetail(ctx, s.DB, viewer, key, storage)
}

type groupDetailQueryer interface {
	publicProfileQueryer
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func readGroupDetail(ctx context.Context, db groupDetailQueryer, viewer int64, key groupLookup, storage StorageURLPolicy) (groupDetail, error) {
	query, bind := groupDetailSQL+"g.group_id=:group_id", sql.Named("group_id", key.id)
	if key.id == 0 {
		query, bind = groupDetailSQL+"g.slug=:slug", sql.Named("slug", key.slug)
	}
	group, owner, err := scanGroupDetail(db.QueryRowContext(ctx, query, sql.Named("viewer_id", viewer), bind), storage)
	if err != nil {
		return groupDetail{}, err
	}
	return hydrateGroupDetail(ctx, db, viewer, group, owner, storage)
}

func scanGroupDetail(row notificationScanner, storage StorageURLPolicy, extra ...any) (groupDetail, int64, error) {
	group := groupDetail{Tags: []string{}}
	var owner, approval int64
	var member sql.NullInt64
	var description, avatar, cover, category, privacyDesc, role, status sql.NullString
	var created, updated, joined sql.NullTime
	destinations := []any{
		&group.ID, &group.Name, &group.Slug, &description, &avatar, &cover, &category, &owner, &group.Privacy,
		&privacyDesc, &approval, &group.PostPermission, &group.MemberCount, &group.PostCount, &group.Active,
		&created, &updated, &member, &role, &status, &joined}
	err := row.Scan(append(destinations, extra...)...)
	if errors.Is(err, sql.ErrNoRows) {
		return groupDetail{}, 0, errGroupDetailMissing
	}
	if err != nil {
		return groupDetail{}, 0, errSessionStore
	}
	group.Description, group.PrivacyDesc, group.JoinApproval = description.String, privacyDesc.String, approval == 1
	group.Category = nullableString(category)
	group.CreatedAt, group.UpdatedAt = timestampOrEmpty(created), timestampOrEmpty(updated)
	if member.Valid {
		group.Membership = groupDetailMembership{true, nullableString(role), nullableString(status), profileDate(joined)}
	}
	for _, asset := range []struct {
		value  string
		target **string
	}{{avatar.String, &group.AvatarURL}, {cover.String, &group.CoverURL}} {
		if asset.value == "" {
			continue
		}
		normalized, err := normalizeAvatarURL(storage, asset.value)
		if err != nil {
			return groupDetail{}, 0, errSessionStore
		}
		*asset.target = &normalized
	}

	return group, owner, nil
}

func (s OracleSessions) hydrateGroupDetail(ctx context.Context, viewer int64, group groupDetail, owner int64, storage StorageURLPolicy) (groupDetail, error) {
	return hydrateGroupDetail(ctx, s.DB, viewer, group, owner, storage)
}

func hydrateGroupDetail(ctx context.Context, db groupDetailQueryer, viewer int64, group groupDetail, owner int64, storage StorageURLPolicy) (groupDetail, error) {
	rows, err := db.QueryContext(ctx, groupTagsSQL, sql.Named("group_id", group.ID))
	if err != nil {
		return groupDetail{}, errSessionStore
	}
	defer rows.Close()
	for rows.Next() {
		var tag string
		if rows.Scan(&tag) != nil {
			return groupDetail{}, errSessionStore
		}
		group.Tags = append(group.Tags, tag)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return groupDetail{}, errSessionStore
	}
	profile, found, err := readPublicProfile(ctx, db, viewer, owner)
	if err != nil {
		return groupDetail{}, errSessionStore
	}
	if !found {
		return groupDetail{}, errGroupOwnerMissing
	}
	profile.AvatarURL, err = normalizeAvatarURL(storage, profile.AvatarURL)
	if err != nil {
		return groupDetail{}, errSessionStore
	}
	group.Owner = profile
	return group, nil
}

func groupDetailRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, storage StorageURLPolicy) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	if !ok || r.Method != http.MethodGet {
		return false
	}
	raw, bySlug := strings.CutPrefix(path, "by-slug/")
	if raw == "" || strings.Contains(raw, "/") || (!bySlug && raw == "popular") {
		return false
	}
	var key groupLookup
	var viewer int64
	if bySlug {
		var valid bool
		viewer, valid = interactionActor(w, r, codec, repository)
		if !valid {
			return true
		}
		slug, err := url.PathUnescape(raw)
		if err != nil || slug == "" {
			respond(w, 400, 40001, "slug 参数错误", nil)
			return true
		}
		key.slug = slug
	} else {
		var valid bool
		viewer, key.id, valid = interactionIdentity(w, r, codec, repository, raw)
		if !valid {
			return true
		}
	}
	store, ok := repository.(groupDetailStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	group, err := store.GroupDetail(r.Context(), viewer, key, storage)
	switch {
	case errors.Is(err, errGroupDetailMissing):
		respond(w, 404, 40401, "群组不存在", nil)
	case errors.Is(err, errGroupOwnerMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, "success", group)
	}
	return true
}
