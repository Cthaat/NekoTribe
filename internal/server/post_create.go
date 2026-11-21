package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"net/http"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postCreateStore interface {
	postDetailStore
	postCreateNoticeStore
	CreatePostAtomic(context.Context, int64, PostCreateInput) (int64, error)
}

var _ postCreateStore = OracleSessions{}

// The two public entry points share parsing, transaction, notification and response mapping.
func createPost(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, rawRetweet string) {
	var user int64
	var repost *int64
	if rawRetweet != "" {
		actor, source, ok := interactionIdentity(w, r, codec, repository, rawRetweet)
		if !ok {
			return
		}
		user, repost = actor, &source
	} else {
		actor, ok := interactionActor(w, r, codec, repository)
		if !ok {
			return
		}
		user = actor
	}
	body, ok := readPostCreateBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	input, message := readPostCreateInput(body, repost)
	if message != "" {
		respond(w, 400, 40001, message, nil)
		return
	}
	store, ok := repository.(postCreateStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	id, err := store.CreatePostAtomic(r.Context(), user, input)
	if err != nil {
		switch {
		case errors.Is(err, errPublishForbidden):
			respond(w, 403, 40301, publishPolicy.Message, nil)
		case errors.Is(err, errPostReferenceUnavailable):
			respond(w, 404, 40401, "帖子不存在", nil)
		case errors.Is(err, errPostMediaUnavailable):
			respond(w, 400, 40001, "媒体不存在或不可用", nil)
		case errors.Is(err, errPostContentEmpty):
			respond(w, 400, 40001, "content 不能为空", nil)
		default:
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return
	}
	if err = notifyPostCreated(r.Context(), repository, store, config, user, id, input); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	post, found, err := store.ReadVisiblePost(r.Context(), &user, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	post, failure := hydratePost(r.Context(), store, &user, post, config.Storage)
	if failure != nil {
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
		return
	}
	message = "post created"
	if input.RepostOfPostID != nil {
		message = "retweet created"
	}
	respond(w, 200, 200, message, post)
}

// JSON.parse accepts valid numeric tokens that overflow to Infinity. Decode
// numbers explicitly so field conversion, not the object reader, decides how
// to handle them. Other Go endpoints retain their existing request policy.
func readPostCreateBody(r *http.Request) (map[string]interface{}, bool) {
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(raw) > 1<<20 {
		return nil, false
	}
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/x-www-form-urlencoded") {
		body := parseLoginForm(raw)
		return body, body != nil
	}
	if strings.HasPrefix(r.Header.Get("Content-Type"), "text/") {
		return nil, false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var body map[string]interface{}
	if decoder.Decode(&body) != nil || body == nil {
		return nil, false
	}
	var trailing interface{}
	if decoder.Decode(&trailing) != io.EOF {
		return nil, false
	}
	for key, value := range body {
		body[key] = postJSONNumbers(value)
	}
	return body, true
}

func postJSONNumbers(value interface{}) interface{} {
	switch v := value.(type) {
	case json.Number:
		// The decoder validated syntax; range overflow intentionally becomes Inf.
		number, _ := v.Float64()
		return number
	case []interface{}:
		for i, item := range v {
			v[i] = postJSONNumbers(item)
		}
	case map[string]interface{}:
		for key, item := range v {
			v[key] = postJSONNumbers(item)
		}
	}
	return value
}

func readPostCreateInput(body map[string]interface{}, repost *int64) (PostCreateInput, string) {
	input := PostCreateInput{Content: registrationString(body["content"]), Visibility: "public"}
	switch body["visibility"].(type) {
	case string, float64, bool:
		input.Visibility = registrationString(body["visibility"])
	}
	switch input.Visibility {
	case "public", "followers", "mentioned", "private":
	default:
		return input, "visibility 参数错误"
	}
	if repost != nil {
		input.RepostOfPostID = repost
		return input, ""
	}
	input.Location = registrationString(body["location"])
	input.MediaIDs = postNumberArray(postBodyField(body, "media_ids", "mediaIds"))
	input.Tags = postStringArray(postBodyField(body, "tag_names", "tagNames"))
	input.Mentions = postNumberArray(postBodyField(body, "mention_user_ids", "mentionUserIds"))
	refs := []struct {
		primary, fallback string
		target            **int64
	}{
		{"reply_to_post_id", "replyToPostId", &input.ReplyToPostID},
		{"repost_of_post_id", "repostOfPostId", &input.RepostOfPostID},
		{"quoted_post_id", "quotedPostId", &input.QuotedPostID},
	}
	count := 0
	for _, ref := range refs {
		id, ok := optionalCommentParent(postBodyField(body, ref.primary, ref.fallback))
		if !ok {
			return input, "id 参数错误"
		}
		*ref.target = id
		if id != nil {
			count++
		}
	}
	if count > 1 {
		return input, "引用字段只能传一个"
	}
	if input.RepostOfPostID == nil && strings.TrimFunc(input.Content, jsTrimSpace) == "" && len(input.MediaIDs) == 0 {
		return input, "content 不能为空"
	}
	return input, ""
}

func postBodyField(body map[string]interface{}, primary, fallback string) interface{} {
	if value, found := body[primary]; found {
		return value
	}
	return body[fallback]
}

func postArray(value interface{}) []interface{} {
	switch values := value.(type) {
	case []interface{}:
		return values
	case []string: // Repeated URL-encoded fields, as returned by readLoginBody.
		out := make([]interface{}, len(values))
		for i, value := range values {
			out[i] = value
		}
		return out
	default:
		return nil
	}
}

func postStringArray(value interface{}) []string {
	result := []string{}
	for _, item := range postArray(value) {
		if text := strings.TrimFunc(registrationString(item), jsTrimSpace); text != "" {
			result = append(result, text)
		}
	}
	return result
}

func postNumberArray(value interface{}) []float64 {
	result := []float64{}
	for _, item := range postArray(value) {
		if number, ok := postNullableNumber(item); ok {
			result = append(result, number)
		}
	}
	return result
}

// Preserve Nuxt's finite Number conversion; do not truncate fractions into different IDs.
func postNullableNumber(value interface{}) (float64, bool) {
	var number float64
	switch v := value.(type) {
	case float64:
		number = v
	case string:
		if v == "" {
			return 0, false
		}
		text := strings.TrimFunc(v, jsTrimSpace)
		if text == "" {
			return 0, true
		}
		if radixNumber.MatchString(text) {
			radix := 16
			switch text[1] {
			case 'b', 'B':
				radix = 2
			case 'o', 'O':
				radix = 8
			}
			n, ok := new(big.Int).SetString(text[2:], radix)
			if !ok {
				return 0, false
			}
			number, _ = new(big.Float).SetInt(n).Float64()
		} else if decimalNumber.MatchString(text) {
			n, err := strconv.ParseFloat(text, 64)
			if err != nil && !errors.Is(err, strconv.ErrRange) {
				return 0, false
			}
			number = n
		} else {
			return 0, false
		}
	default:
		return 0, false
	}
	return number, !math.IsInf(number, 0) && !math.IsNaN(number)
}
