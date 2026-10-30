package server

import (
	"context"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

type aiConversationStore interface {
	createAIConversation(context.Context, int64, conversationInput, moderationPolicy) (conversationRecord, error)
	readAIConversation(context.Context, int64, string, moderationPolicy) (conversationRecord, error)
	appendAIUserMessage(context.Context, int64, string, string, moderationPolicy) (conversationMessage, error)
	listAIConversationMessages(context.Context, int64, string, int64, int64, moderationPolicy) ([]conversationHistoryMessage, error)
}

var aiDecimal = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

func aiConversationRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	const prefix = "/api/v2/ai/conversations"
	path := r.URL.EscapedPath()
	if path != prefix && !strings.HasPrefix(path, prefix+"/") {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	parts := strings.Split(strings.TrimPrefix(path, prefix), "/")
	operation := ""
	id := ""
	if path == prefix && r.Method == http.MethodPost {
		operation = "create"
	} else if len(parts) == 2 && parts[0] == "" && parts[1] != "" && r.Method == http.MethodGet {
		operation = "read"
		id = parts[1]
	} else if len(parts) == 3 && parts[0] == "" && parts[1] != "" && parts[2] == "messages" {
		id = parts[1]
		if r.Method == http.MethodGet {
			operation = "list"
		} else if r.Method == http.MethodPost {
			operation = "append"
		}
	} else if len(parts) == 3 && parts[0] == "" && parts[1] != "" && parts[2] == "generate" && r.Method == http.MethodPost {
		id = parts[1]
		operation = "generate"
	}
	if operation == "" {
		respond(w, 404, 40404, "API route not found", nil)
		return true
	}
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	if id != "" {
		decoded, err := url.PathUnescape(id)
		if err != nil || !conversationUUID.MatchString(decoded) {
			respond(w, 404, 40401, "会话不存在", nil)
			return true
		}
		id = decoded
	}
	store, ok := repository.(aiConversationStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	policy := conversationPolicy(config.ModerationAllowAll, config.ModerationAdminAccounts)
	var result interface{}
	var err error
	switch operation {
	case "create":
		body, valid := readPostCreateBody(r)
		if !valid {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		input, valid := parseAIConversationInput(body)
		if !valid {
			respond(w, 400, 40001, "会话参数错误", nil)
			return true
		}
		result, err = store.createAIConversation(r.Context(), actor, input, policy)
	case "read":
		result, err = store.readAIConversation(r.Context(), actor, id, policy)
	case "append":
		body, valid := readPostCreateBody(r)
		if !valid {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		content, valid := body["content"].(string)
		if len(body) != 1 || !valid || content == "" || len(content) > 65536 {
			respond(w, 400, 40001, "消息参数错误", nil)
			return true
		}
		result, err = store.appendAIUserMessage(r.Context(), actor, id, content, policy)
	case "list":
		query := parseSessionQuery(r.URL.RawQuery)
		after, valid := aiPageParam(query, "after_sequence", 0, 9999999999)
		if !valid {
			respond(w, 400, 40001, "分页参数错误", nil)
			return true
		}
		limit, valid := aiPageParam(query, "limit", 20, 50)
		if !valid || limit == 0 {
			respond(w, 400, 40001, "分页参数错误", nil)
			return true
		}
		result, err = store.listAIConversationMessages(r.Context(), actor, id, after, limit, policy)
	case "generate":
		writer, ok := repository.(aiWritingStore)
		if !ok {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return true
		}
		result, err = generateAIWriting(r.Context(), writer, actor, id, policy, config)
	}
	if err != nil {
		switch {
		case errors.Is(err, errConversationInvalid):
			respond(w, 400, 40001, "会话参数错误", nil)
		case errors.Is(err, errConversationNotFound):
			respond(w, 404, 40401, "会话不存在", nil)
		case errors.Is(err, errConversationForbidden):
			respond(w, 403, 40301, "权限不足", nil)
		case errors.Is(err, errConversationSchema):
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		case errors.Is(err, errConversationConflict):
			respond(w, 409, 40901, "会话已变更，请重试", nil)
		case errors.Is(err, errWritingContext):
			respond(w, 400, 40001, "写作会话上下文不可用", nil)
		case errors.Is(err, errWritingUnavailable):
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		default:
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return true
	}
	respond(w, 200, 200, "success", result)
	return true
}
func aiPageParam(values url.Values, key string, fallback, max int64) (int64, bool) {
	items, found := values[key]
	if !found {
		return fallback, true
	}
	if len(items) != 1 || !aiDecimal.MatchString(items[0]) {
		return 0, false
	}
	n, err := strconv.ParseInt(items[0], 10, 64)
	return n, err == nil && n <= max
}
func parseAIConversationInput(body map[string]interface{}) (conversationInput, bool) {
	for key := range body {
		if key != "purpose" && key != "group_id" && key != "title" {
			return conversationInput{}, false
		}
	}
	purpose, ok := body["purpose"].(string)
	if !ok {
		return conversationInput{}, false
	}
	input := conversationInput{Purpose: purpose}
	if value := body["group_id"]; value != nil {
		group, ok := value.(float64)
		if !ok || math.IsNaN(group) || math.IsInf(group, 0) || group != math.Trunc(group) || group <= 0 || group > 9007199254740991 {
			return input, false
		}
		id := int64(group)
		input.GroupID = &id
	}
	if value := body["title"]; value != nil {
		title, ok := value.(string)
		if !ok {
			return input, false
		}
		input.Title = title
	}
	input, err := validateConversationInput(input)
	return input, err == nil
}
