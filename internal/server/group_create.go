package server

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

type groupCreateStore interface {
	CreateGroup(context.Context, int64, groupSettingsPatch, StorageURLPolicy) (groupDetail, error)
}

const insertGroupSQL = `INSERT INTO n_groups
(group_id,name,slug,description,avatar_url,cover_url,category,owner_id,privacy,join_approval,post_permission)
VALUES (:group_id,:name,:slug,:description,:avatar_url,:cover_url,:category,:owner_id,:privacy,:join_approval,:post_permission)`
const insertGroupOwnerSQL = `INSERT INTO n_group_members (group_id,user_id,role,status)
VALUES (:group_id,:owner_id,'owner','active')`
const createGroupAuditSQL = `INSERT INTO n_group_audit_logs (group_id,actor_id,action)
VALUES (:group_id,:owner_id,'create_group')`

var groupSlugSeparators = regexp.MustCompile(`[^a-z0-9一-龥]+`)

func groupSlug(name string, id int64) string {
	suffix := "-" + strconv.FormatInt(id, 10)
	base := strings.Trim(groupSlugSeparators.ReplaceAllString(cases.Lower(language.Und).String(name), "-"), "-")
	for len(base)+len(suffix) > 100 {
		_, size := utf8.DecodeLastRuneInString(base)
		base = base[:len(base)-size]
	}
	base = strings.TrimRight(base, "-")
	if base == "" {
		base = "group"
	}
	return base + suffix
}

func parseNewGroup(raw []byte) (groupSettingsPatch, string) {
	input, invalid := parseGroupSettings(raw)
	if invalid != "" {
		return input, invalid
	}
	name, ok := input.fields["name"].(string)
	if !ok {
		return input, "name 参数错误"
	}
	input.fields["name"] = strings.TrimFunc(name, jsTrimSpace)
	for key, defaultValue := range map[string]any{"privacy": "public", "join_approval": 0, "post_permission": "all"} {
		if _, supplied := input.fields[key]; !supplied {
			input.fields[key] = defaultValue
		}
	}
	return input, ""
}

func (s OracleSessions) CreateGroup(ctx context.Context, actor int64, input groupSettingsPatch, storage StorageURLPolicy) (groupDetail, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return groupDetail{}, errSessionStore
	}
	defer tx.Rollback()

	if err := lockGroupImages(ctx, tx, input.fields, storage); err != nil {
		return groupDetail{}, err
	}
	var group int64
	if err := tx.QueryRowContext(ctx, "SELECT seq_group_id.NEXTVAL AS id FROM dual").Scan(&group); err != nil || group < 1 || group > maxSocketID {
		return groupDetail{}, errSessionStore
	}
	gb, owner := sql.Named("group_id", group), sql.Named("owner_id", actor)
	name, ok := input.fields["name"].(string)
	if !ok {
		return groupDetail{}, errSessionStore
	}
	binds := []any{gb, owner, sql.Named("slug", groupSlug(name, group))}
	for _, column := range groupSettingsColumns {
		binds = append(binds, sql.Named(column, input.fields[column]))
	}
	if writeOneChatRow(ctx, tx, insertGroupSQL, binds...) != nil ||
		writeOneChatRow(ctx, tx, insertGroupOwnerSQL, gb, owner) != nil {
		return groupDetail{}, errSessionStore
	}
	if insertGroupTags(ctx, tx, gb, input.tags) != nil {
		return groupDetail{}, errSessionStore
	}
	if writeOneChatRow(ctx, tx, createGroupAuditSQL, gb, owner) != nil {
		return groupDetail{}, errSessionStore
	}
	result, err := readGroupDetail(ctx, tx, actor, groupLookup{id: group}, storage)
	if err != nil || tx.Commit() != nil {
		return groupDetail{}, errSessionStore
	}
	return result, nil
}

func groupCreateRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	if r.Method != http.MethodPost || r.URL.EscapedPath() != "/api/v2/groups" {
		return false
	}
	actor, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(raw) > 1<<20 {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	input, invalid := parseNewGroup(raw)
	if invalid != "" {
		respond(w, 400, 40001, invalid, nil)
		return true
	}
	store, ok := repo.(groupCreateStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	detail, err := store.CreateGroup(r.Context(), actor, input, storage)
	if errors.Is(err, errGroupImageMissing) {
		respond(w, 400, 40001, errGroupImageMissing.message, nil)
	} else if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
	} else {
		respond(w, 200, 200, "group created", detail)
	}
	return true
}
