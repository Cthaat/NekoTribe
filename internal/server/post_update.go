package server

import (
	"context"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"net/http"
	"regexp"
	"strings"
)

type PostUpdateInput struct {
	Content    *string    `json:"content,omitempty"`
	Visibility *string    `json:"visibility,omitempty"`
	Language   *string    `json:"language,omitempty"`
	Location   *string    `json:"location,omitempty"`
	MediaIDs   *[]float64 `json:"media_ids,omitempty"`
	Tags       *[]string  `json:"tag_names,omitempty"`
	Mentions   *[]float64 `json:"mention_user_ids,omitempty"`
}

var postLanguagePattern = regexp.MustCompile(`^[a-z]{2}(-[a-z0-9]{2,7})?$`)

func readPostUpdateInput(body map[string]interface{}) (PostUpdateInput, string) {
	input := PostUpdateInput{}
	if value, present := body["content"]; present {
		v := registrationString(value)
		input.Content = &v
	}
	if value, present := body["visibility"]; present {
		v := registrationString(value)
		switch v {
		case "public", "followers", "mentioned", "private":
			input.Visibility = &v
		default:
			return input, "visibility 参数错误"
		}
	}
	if value, present := body["language"]; present {
		v := strings.ToLower(strings.TrimFunc(registrationString(value), jsTrimSpace))
		if v == "" {
			v = "zh"
		}
		if !postLanguagePattern.MatchString(v) {
			return input, "language 参数错误"
		}
		input.Language = &v
	}
	if value, present := body["location"]; present {
		v := registrationString(value)
		input.Location = &v
	}
	if postHasField(body, "media_ids", "mediaIds") {
		v := postNumberArray(postBodyField(body, "media_ids", "mediaIds"))
		input.MediaIDs = &v
	}
	if postHasField(body, "tag_names", "tagNames") {
		v := postStringArray(postBodyField(body, "tag_names", "tagNames"))
		input.Tags = &v
	}
	if postHasField(body, "mention_user_ids", "mentionUserIds") {
		v := postNumberArray(postBodyField(body, "mention_user_ids", "mentionUserIds"))
		input.Mentions = &v
	}
	return input, ""
}
func postHasField(body map[string]interface{}, primary, fallback string) bool {
	_, a := body[primary]
	_, b := body[fallback]
	return a || b
}

type postUpdateStore interface {
	postDetailStore
	UpdatePostAtomic(context.Context, int64, int64, PostUpdateInput) error
}

var _ postUpdateStore = OracleSessions{}

func updatePost(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	actor, id, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	body, ok := readPostCreateBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	input, message := readPostUpdateInput(body)
	if message != "" {
		respond(w, 400, 40001, message, nil)
		return
	}
	store, ok := repository.(postUpdateStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if err := store.UpdatePostAtomic(r.Context(), actor, id, input); err != nil {
		switch {
		case errors.Is(err, errPostReferenceUnavailable):
			respond(w, 404, 40401, "帖子不存在", nil)
		case errors.Is(err, errPostUpdateNotOwner):
			respond(w, 422, 42201, "只能修改自己的帖子", nil)
		case errors.Is(err, errPostUpdateMedia):
			respond(w, 400, 40001, "附件不存在或无权使用", nil)
		case errors.Is(err, errPostContentEmpty):
			respond(w, 400, 40001, "content 不能为空", nil)
		default:
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return
	}
	post, found, err := store.ReadVisiblePost(r.Context(), &actor, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	post, failure := hydratePost(r.Context(), store, &actor, post, config.Storage)
	if failure != nil {
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
		return
	}
	respond(w, 200, 200, "post updated", post)
}
