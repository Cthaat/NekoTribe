package server

import (
	"cmp"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

type groupSettingsPatch struct {
	fields      map[string]any
	tags        []string
	replaceTags bool
}

type groupSettingsStore interface {
	PatchGroupSettings(context.Context, int64, int64, groupSettingsPatch, StorageURLPolicy) (groupDetail, error)
}

var groupSettingsColumns = []string{"name", "description", "avatar_url", "cover_url", "privacy", "join_approval", "post_permission", "category"}
var errGroupImageMissing = &groupMembershipFailure{400, "群组图片不存在或已删除"}

func lockGroupImages(ctx context.Context, tx *sql.Tx, fields map[string]any, storage StorageURLPolicy) error {
	avatar, _ := fields["avatar_url"].(string)
	cover, _ := fields["cover_url"].(string)
	urls := []string{avatar, cover}
	if err := lockGroupMediaURLs(ctx, tx, urls, storage); err != nil {
		return err
	}
	if urls[0] != avatar {
		fields["avatar_url"] = urls[0]
	}
	if urls[1] != cover {
		fields["cover_url"] = urls[1]
	}
	return nil
}

func lockGroupMediaURLs(ctx context.Context, tx *sql.Tx, urls []string, storage StorageURLPolicy) error {
	keys := make([]string, 0, len(urls))
	targets := make(map[int]string)
	for index, url := range urls {
		if key := managedGroupImageKey(storage, url); key != "" {
			targets[index] = key
			if !slices.Contains(keys, key) {
				keys = append(keys, key)
			}
		}
	}
	type mediaRow struct {
		id  int64
		key string
	}
	matches := make([]mediaRow, 0, len(keys))
	for pair := range slices.Chunk(keys, 2) {
		rows, err := tx.QueryContext(ctx, mediaReferences.LookupGroupImages,
			sql.Named("first_key", pair[0]), sql.Named("second_key", pair[len(pair)-1]))
		if err != nil {
			return errSessionStore
		}
		for rows.Next() {
			var media mediaRow
			if err := rows.Scan(&media.id, &media.key); err != nil {
				_ = rows.Close()
				return errSessionStore
			}
			matches = append(matches, media)
		}
		if closeErr := rows.Close(); closeErr != nil || rows.Err() != nil {
			return errSessionStore
		}
	}
	if len(matches) != len(keys) {
		return errGroupImageMissing
	}
	slices.SortFunc(matches, func(a, b mediaRow) int { return cmp.Compare(a.id, b.id) })
	locked := make(map[string]string, len(keys))
	for _, media := range matches {
		var url string
		err := tx.QueryRowContext(ctx, mediaReferences.LockGroupImage,
			sql.Named("media_id", media.id), sql.Named("storage_key", media.key)).Scan(&url)
		if errors.Is(err, sql.ErrNoRows) || err == nil && url == "" {
			return errGroupImageMissing
		}
		if err != nil {
			return errSessionStore
		}
		linked, err := directAssetLinked(ctx, tx, sql.Named("media_id", media.id))
		if err != nil {
			return err
		}
		if linked {
			return errGroupImageMissing
		}
		locked[media.key] = url
	}
	for index, key := range targets {
		url := locked[key]
		if url == "" {
			return errGroupImageMissing
		}
		urls[index] = url
	}
	return nil
}

const groupClearTagsSQL = "DELETE FROM n_group_tags WHERE group_id=:group_id"
const groupInsertTagSQL = "INSERT INTO n_group_tags (group_id,tag,tag_lower) VALUES (:group_id,:tag,:tag_lower)"

func parseGroupSettings(raw []byte) (groupSettingsPatch, string) {
	var input map[string]json.RawMessage
	patch := groupSettingsPatch{fields: make(map[string]any)}
	if json.Unmarshal(raw, &input) != nil || input == nil {
		return patch, "请求体必须是 JSON 对象"
	}
	for _, key := range groupSettingsColumns {
		value, found := input[key]
		if !found {
			continue
		}
		if key == "join_approval" {
			var b *bool
			if json.Unmarshal(value, &b) != nil || b == nil {
				return patch, key + " 参数错误"
			}
			n := 0
			if *b {
				n = 1
			}
			patch.fields[key] = n
			continue
		}
		var text *string
		if json.Unmarshal(value, &text) != nil {
			return patch, key + " 参数错误"
		}
		nullable := key == "description" || key == "avatar_url" || key == "cover_url" || key == "category"
		if text == nil {
			if !nullable {
				return patch, key + " 参数错误"
			}
			patch.fields[key] = nil
			continue
		}
		s := *text
		switch key {
		case "name":
			if strings.TrimFunc(s, jsTrimSpace) == "" || len(s) > 100 {
				return patch, key + " 参数错误"
			}
		case "description", "avatar_url", "cover_url":
			if len(s) > 500 {
				return patch, key + " 参数错误"
			}
		case "privacy":
			if !slices.Contains([]string{"public", "private", "secret"}, s) {
				return patch, key + " 参数错误"
			}
		case "post_permission":
			if !slices.Contains([]string{"all", "admin_only", "moderator_up"}, s) {
				return patch, key + " 参数错误"
			}
		case "category":
			s = strings.TrimFunc(s, jsTrimSpace)
			if s != "" && !slices.Contains([]string{"tech", "game", "music", "art", "life", "study", "work", "other"}, s) {
				return patch, key + " 参数错误"
			}
		}
		if s == "" && nullable {
			patch.fields[key] = nil
		} else {
			patch.fields[key] = s
		}
	}
	rawTags, found := input["tags"]
	if !found {
		return patch, ""
	}
	var tags []*string
	if json.Unmarshal(rawTags, &tags) != nil || tags == nil {
		return patch, "tags 参数错误"
	}
	for _, tag := range tags {
		if tag == nil {
			return patch, "tags 参数错误"
		}
	}
	patch.replaceTags = true
	seen := make(map[string]bool)
	lower := cases.Lower(language.Und)
	for _, tag := range tags {
		s := strings.TrimFunc(strings.TrimPrefix(strings.TrimFunc(*tag, jsTrimSpace), "#"), jsTrimSpace)
		for len(s) > 50 || len(lower.String(s)) > 50 {
			_, size := utf8.DecodeLastRuneInString(s)
			s = s[:len(s)-size]
		}
		key := lower.String(s)
		if s == "" || seen[key] {
			continue
		}
		seen[key] = true
		patch.tags = append(patch.tags, s)
		if len(patch.tags) == 8 {
			break
		}
	}
	return patch, ""
}

func (s OracleSessions) PatchGroupSettings(ctx context.Context, viewer, group int64, patch groupSettingsPatch, storage StorageURLPolicy) (groupDetail, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return groupDetail{}, errSessionStore
	}
	defer tx.Rollback()
	gb := sql.Named("group_id", group)
	var owner, approval, active, deleted int64
	var privacy string
	err = tx.QueryRowContext(ctx, membershipGroupSQL, gb).Scan(&owner, &privacy, &approval, &active, &deleted)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (active != 1 || deleted != 0) {
		return groupDetail{}, errGroupDetailMissing
	}
	if err != nil {
		return groupDetail{}, errSessionStore
	}
	var role, status string
	err = tx.QueryRowContext(ctx, membershipReadSQL, gb, sql.Named("user_id", viewer)).Scan(&role, &status)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (status != "active" || !(role == "admin" || role == "owner" && owner == viewer)) {
		return groupDetail{}, &groupMembershipFailure{422, "无权修改群组"}
	}
	if err != nil {
		return groupDetail{}, errSessionStore
	}
	if err := lockGroupImages(ctx, tx, patch.fields, storage); err != nil {
		return groupDetail{}, err
	}
	args := []any{gb}
	var clauses []string
	for _, key := range groupSettingsColumns {
		if value, ok := patch.fields[key]; ok {
			clauses = append(clauses, key+"=:"+key)
			args = append(args, sql.Named(key, value))
		}
	}
	if len(clauses) > 0 || patch.replaceTags {
		clauses = append(clauses, "updated_at=SYSTIMESTAMP")
		if writeOneChatRow(ctx, tx, "UPDATE n_groups SET "+strings.Join(clauses, ",")+" WHERE group_id=:group_id", args...) != nil {
			return groupDetail{}, errSessionStore
		}
	}
	if patch.replaceTags {
		if _, err := tx.ExecContext(ctx, groupClearTagsSQL, gb); err != nil {
			return groupDetail{}, errSessionStore
		}
		if insertGroupTags(ctx, tx, gb, patch.tags) != nil {
			return groupDetail{}, errSessionStore
		}
	}
	result, err := readGroupDetail(ctx, tx, viewer, groupLookup{id: group}, storage)
	if err != nil {
		return groupDetail{}, err
	}
	if tx.Commit() != nil {
		return groupDetail{}, errSessionStore
	}
	return result, nil
}

func insertGroupTags(ctx context.Context, tx *sql.Tx, group sql.NamedArg, tags []string) error {
	lower := cases.Lower(language.Und)
	for _, tag := range tags {
		if err := writeOneChatRow(ctx, tx, groupInsertTagSQL, group, sql.Named("tag", tag), sql.Named("tag_lower", lower.String(tag))); err != nil {
			return err
		}
	}
	return nil
}

func groupSettingsRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	id, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	if r.Method != http.MethodPatch || !ok || id == "" || strings.Contains(id, "/") {
		return false
	}
	viewer, group, ok := interactionIdentity(w, r, codec, repo, id)
	if !ok {
		return true
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(raw) > 1<<20 {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	patch, validation := parseGroupSettings(raw)
	if validation != "" {
		respond(w, 400, 40001, validation, nil)
		return true
	}
	store, ok := repo.(groupSettingsStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	result, err := store.PatchGroupSettings(r.Context(), viewer, group, patch, storage)
	var failure *groupMembershipFailure
	switch {
	case errors.As(err, &failure):
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case errors.Is(err, errGroupDetailMissing):
		respond(w, 404, 40401, "群组不存在", nil)
	case errors.Is(err, errGroupOwnerMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, "group updated", result)
	}
	return true
}
