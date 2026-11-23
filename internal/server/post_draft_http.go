package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postDraftStore interface {
	ListPostDrafts(context.Context, int64, postDraftQuery) (postDraftList, error)
	ChangePostDraft(context.Context, int64, postDraftAction, RefreshConfig) (*postDraftRecord, error)
}

func parsePostDraftQuery(raw string) (postDraftQuery, error) {
	query := postDraftQuery{limit: postDrafts.DefaultLimit}
	values := parseSessionQuery(raw)
	for field, dest := range map[string]**int64{
		"before_id": &query.before, "group_id": &query.group,
	} {
		if value, present := values[field]; present {
			if len(value) != 1 {
				return query, errPostDraftInvalid
			}
			if value[0] == "0" && field == "group_id" {
				var ordinary int64
				*dest = &ordinary
			} else if number, valid := postDraftDecimal(value[0]); valid {
				*dest = &number
			} else {
				return query, errPostDraftInvalid
			}
		}
	}
	if val, present := values["limit"]; present {
		if len(val) != 1 {
			return query, errPostDraftInvalid
		}
		n, valid := postDraftDecimal(val[0])
		if !valid || n > int64(postDrafts.MaxLimit) {
			return query, errPostDraftInvalid
		}
		query.limit = int(n)
	}
	return query, nil
}

func postDraftDecimal(value string) (int64, bool) {
	if !publicID.MatchString(value) {
		return 0, false
	}
	n, err := strconv.ParseInt(value, 10, 64)
	return n, err == nil && n <= maxSocketID
}

func parsePostDraftSchedule(raw []byte) (time.Time, error) {
	var body map[string]any
	if json.Unmarshal(raw, &body) != nil || len(body) != 1 {
		return time.Time{}, errPostDraftInvalid
	}
	text, ok := body["scheduled_at"].(string)
	if !ok {
		return time.Time{}, errPostDraftInvalid
	}
	at, ok := parsePostUTCDate(text)
	if !ok {
		return time.Time{}, errPostDraftInvalid
	}
	return at, nil
}

func postDraftFailure(err error) postFailure {
	var group *groupMembershipFailure
	switch {
	case errors.Is(err, errPostDraftInvalid), errors.Is(err, errPostCreateInvalid), errors.Is(err, errPostPollInvalid):
		return postFailure{400, "草稿参数错误"}
	case errors.Is(err, errPostDraftSchedule):
		return postFailure{400, "定时发布时间必须晚于当前时间"}
	case errors.Is(err, errPostDraftPollCutoff):
		return postFailure{400, "投票截止时间必须晚于定时发布时间"}
	case errors.Is(err, errPostPollCutoff):
		return *postPollFailure(err)
	case errors.Is(err, errPostMarkdownInvalid), errors.Is(err, errPostMarkdownUnavailable):
		return *postMarkdownFailure(err)
	case errors.Is(err, errPostContentEmpty):
		return postFailure{400, "content 不能为空"}
	case errors.Is(err, errPostMediaUnavailable):
		return postFailure{400, "媒体不存在或不可用"}
	case errors.Is(err, errPostDraftMissing):
		return postFailure{404, "草稿不存在"}
	case errors.Is(err, errGroupDetailMissing):
		return postFailure{404, "群组不存在"}
	case errors.Is(err, errPostReferenceUnavailable):
		return postFailure{404, "帖子不存在"}
	case errors.Is(err, errPublishForbidden):
		return postFailure{403, publishPolicy.Message}
	case errors.As(err, &group):
		return postFailure{group.status, group.message}
	case errors.Is(err, errPostDraftPublished):
		return postFailure{409, "草稿已发布"}
	case errors.Is(err, errPostDraftUnavailable), errors.Is(err, errPostPollUnavailable):
		return postFailure{503, "草稿服务暂不可用"}
	default:
		return postFailure{500, "服务器内部错误"}
	}
}

func postDraftRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	const path = "/api/v2/users/me/drafts"
	relative, ok := strings.CutPrefix(r.URL.EscapedPath(), path)
	if !ok || relative != "" && !strings.HasPrefix(relative, "/") {
		return false
	}
	var action postDraftAction
	var rawID string
	if relative == "" {
		switch r.Method {
		case http.MethodGet:
			action.kind = "list"
		case http.MethodPost:
			action.kind = "create"
		default:
			return false
		}
	} else {
		var suffix string
		var nested bool
		rawID, suffix, nested = strings.Cut(relative[1:], "/")
		switch {
		case !nested && r.Method == http.MethodPut:
			action.kind = "edit"
		case !nested && r.Method == http.MethodDelete:
			action.kind = "remove"
		case suffix == "schedule" && r.Method == http.MethodPut:
			action.kind = "schedule"
		case suffix == "schedule" && r.Method == http.MethodDelete:
			action.kind = "unschedule"
		case suffix == "publish" && r.Method == http.MethodPost:
			action.kind = "publish"
		default:
			return false
		}
	}
	owner, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	if relative != "" {
		action.id, ok = groupContentPostID(rawID)
		if !ok {
			respond(w, 400, 40001, "id 参数错误", nil)
			return true
		}
	}
	store, ok := repo.(postDraftStore)
	if !ok {
		respond(w, 503, 50301, "草稿服务暂不可用", nil)
		return true
	}
	if action.kind == "list" {
		query, err := parsePostDraftQuery(r.URL.RawQuery)
		if err == nil {
			var list postDraftList
			list, err = store.ListPostDrafts(r.Context(), owner, query)
			if err == nil {
				respond(w, 200, 200, "success", list)
				return true
			}
		}
		failure := postDraftFailure(err)
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
		return true
	}
	if action.kind == "create" || action.kind == "edit" || action.kind == "schedule" {
		raw, err := io.ReadAll(io.LimitReader(r.Body, int64(postDrafts.MaxPayload+1)))
		if err == nil && len(raw) <= postDrafts.MaxPayload {
			if action.kind == "schedule" {
				action.when, err = parsePostDraftSchedule(raw)
			} else {
				action.body, err = parsePostDraft(raw)
			}
		} else {
			err = errPostDraftInvalid
		}
		if err != nil {
			failure := postDraftFailure(err)
			respond(w, failure.status, failure.status*100+1, failure.message, nil)
			return true
		}
	}
	draft, err := store.ChangePostDraft(r.Context(), owner, action, config)
	if err != nil {
		failure := postDraftFailure(err)
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
		return true
	}
	message := map[string]string{
		"create": "draft saved", "edit": "draft saved", "remove": "draft deleted",
		"schedule": "draft scheduled", "unschedule": "draft unscheduled", "publish": "draft published",
	}[action.kind]
	respond(w, 200, 200, message, draft)
	return true
}
