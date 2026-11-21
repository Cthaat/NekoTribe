package server

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

type aiConversationStore interface {
	createAIConversation(context.Context, int64, conversationInput, moderationPolicy) (conversationRecord, error)
	readAIConversation(context.Context, int64, string, moderationPolicy) (conversationRecord, error)
	deleteAIConversation(context.Context, int64, string, moderationPolicy) error
	appendAIUserMessage(context.Context, int64, string, string, moderationPolicy) (conversationMessage, error)
	listAIConversationMessages(context.Context, int64, string, int64, int64, int64, moderationPolicy) ([]conversationHistoryMessage, error)
	listAIConversations(context.Context, int64, string, int, string, *int64, string, moderationPolicy) (conversationPage, error)
}

var aiDecimal = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

func aiConversationRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	if aiAvailabilityRoute(w, r, codec, repository, config) {
		return true
	}
	const prefix = "/api/v2/ai/conversations"
	path := r.URL.EscapedPath()
	if path != prefix && !strings.HasPrefix(path, prefix+"/") {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	parts := strings.Split(strings.TrimPrefix(path, prefix), "/")
	operation := ""
	id := ""
	messageID := ""
	if path == prefix && (r.Method == http.MethodPost || r.Method == http.MethodGet) {
		if r.Method == http.MethodPost {
			operation = "create"
		} else {
			operation = "list-owned"
		}
	} else if len(parts) == 2 && parts[0] == "" && parts[1] != "" && (r.Method == http.MethodGet || r.Method == http.MethodDelete) {
		if r.Method == http.MethodGet {
			operation = "read"
		} else {
			operation = "delete"
		}
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
	} else if len(parts) == 3 && parts[0] == "" && parts[1] != "" && parts[2] == "knowledge-generate" && r.Method == http.MethodPost {
		id = parts[1]
		operation = "knowledge-generate"
	} else if len(parts) == 3 && parts[0] == "" && parts[1] != "" && parts[2] == "group-generate" && r.Method == http.MethodPost {
		id = parts[1]
		operation = "group-generate"
	} else if len(parts) == 3 && parts[0] == "" && parts[1] != "" && parts[2] == "moderation-generate" && r.Method == http.MethodPost {
		id = parts[1]
		operation = "moderation-generate"
	} else if len(parts) == 5 && parts[0] == "" && parts[1] != "" && parts[2] == "messages" && parts[3] != "" && parts[4] == "moderation-feedback" && r.Method == http.MethodPut {
		id, messageID, operation = parts[1], parts[3], "moderation-feedback"
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
	case "list-owned":
		query := parseSessionQuery(r.URL.RawQuery)
		after := ""
		if values, found := query["after_id"]; found {
			if len(values) != 1 || (values[0] != "" && !conversationUUID.MatchString(values[0])) {
				respond(w, 400, 40001, "分页参数错误", nil)
				return true
			}
			after = values[0]
		}
		limit, valid := aiPageParam(query, "limit", 20, 50)
		if !valid || limit == 0 {
			respond(w, 400, 40001, "分页参数错误", nil)
			return true
		}
		purpose := ""
		if values, found := query["purpose"]; found {
			if len(values) != 1 || values[0] == "" || !validListPurpose(values[0]) {
				respond(w, 400, 40001, "会话用途错误", nil)
				return true
			}
			purpose = values[0]
		}
		var groupID *int64
		if _, found := query["group_id"]; found {
			value, valid := aiPageParam(query, "group_id", 0, 9007199254740991)
			if purpose != "group" || !valid || value < 1 {
				respond(w, 400, 40001, "群组参数错误", nil)
				return true
			}
			groupID = &value
		}
		targetTitle := ""
		kinds, hasKind := query["target_type"]
		_, hasTarget := query["target_id"]
		if hasKind || hasTarget {
			targetID, valid := aiPageParam(query, "target_id", 0, 999999999999999)
			if purpose != "moderation" || len(kinds) != 1 || moderationAdviceContract.Queries[kinds[0]] == "" ||
				!valid || targetID < 1 {
				respond(w, 400, 40001, "审核对象错误", nil)
				return true
			}
			targetTitle = "moderation:" + kinds[0] + ":" + strconv.FormatInt(targetID, 10)
		}
		result, err = store.listAIConversations(r.Context(), actor, after, int(limit), purpose, groupID, targetTitle, policy)
	case "create":
		body, valid := readAIConversationBody(r)
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
	case "delete":
		err = store.deleteAIConversation(r.Context(), actor, id, policy)
	case "append":
		body, valid := readAIConversationBody(r)
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
		before, valid := aiPageParam(query, "before_sequence", 0, 10000000000)
		if !valid || (query.Has("before_sequence") && (before == 0 || query.Has("after_sequence"))) {
			respond(w, 400, 40001, "分页参数错误", nil)
			return true
		}
		limit, valid := aiPageParam(query, "limit", 20, 50)
		if !valid || limit == 0 {
			respond(w, 400, 40001, "分页参数错误", nil)
			return true
		}
		result, err = store.listAIConversationMessages(r.Context(), actor, id, after, before, limit, policy)
	case "generate":
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		input, parseErr := parseWritingRequest(body)
		if readErr != nil || parseErr != nil {
			respond(w, 400, 40001, "写作生成参数错误", nil)
			return true
		}
		writer, ok := repository.(aiWritingStore)
		if !ok {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return true
		}
		result, err = generateAIWriting(r.Context(), writer, actor, id, policy, config, input)
	case "group-generate":
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		request, parseErr := parseGroupDraftRequest(body)
		if readErr != nil || len(body) > 4096 || parseErr != nil {
			respond(w, 400, 40001, "群运营草稿参数错误", nil)
			return true
		}
		group, ok := repository.(groupDraftStore)
		if !ok {
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
			return true
		}
		var message *conversationMessage
		message, err = generateGroupDraft(r.Context(), group, actor, id, policy, config, request)
		if err == nil {
			status := "generated"
			if message == nil {
				status = "insufficient_evidence"
			}
			result = map[string]interface{}{"status": status, "message": message}
		}
	case "moderation-generate":
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		request, parseErr := parseModerationAdviceRequest(body)
		if readErr != nil || len(body) > 4096 || parseErr != nil {
			respond(w, 400, 40001, "审核建议参数错误", nil)
			return true
		}
		moderation, ok := repository.(moderationAdviceStore)
		if !ok {
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
			return true
		}
		var message *conversationMessage
		message, err = generateModerationAdvice(r.Context(), moderation, actor, id, policy, config, request)
		if err == nil {
			status := "generated"
			if message == nil {
				status = "insufficient_evidence"
			}
			result = map[string]interface{}{"status": status, "message": message}
		}
	case "moderation-feedback":
		messageID, decodeErr := url.PathUnescape(messageID)
		if decodeErr != nil || !conversationUUID.MatchString(messageID) {
			respond(w, 404, 40401, "会话不存在", nil)
			return true
		}
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		rating, valid := parseModerationRating(body)
		if readErr != nil || len(body) > 4096 || !valid {
			respond(w, 400, 40001, "审核反馈参数错误", nil)
			return true
		}
		feedback, ok := repository.(moderationFeedbackStore)
		if !ok {
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
			return true
		}
		result, err = feedback.saveModerationFeedback(r.Context(), actor, id, messageID, rating, policy)
	case "knowledge-generate":
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		if readErr != nil || len(body) > 4096 {
			respond(w, 400, 40001, "知识检索参数错误", nil)
			return true
		}
		input, parseErr := parseKnowledgeSearchBody(body)
		if parseErr != nil {
			respond(w, 400, 40001, "知识检索参数错误", nil)
			return true
		}
		knowledge, ok := repository.(knowledgeConversationStore)
		if !ok {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return true
		}
		var message *conversationMessage
		message, err = generateKnowledgeConversation(r.Context(), knowledge, actor, id, policy, config, input)
		if err == nil {
			status := "generated"
			if message == nil {
				status = "insufficient_evidence"
			}
			result = map[string]interface{}{"status": status, "message": message}
		}
	}
	if err != nil {
		var exhausted aiQuotaExceeded
		switch {
		case errors.As(err, &exhausted):
			w.Header().Set("Retry-After", strconv.FormatInt(exhausted.retryAfter, 10))
			respond(w, 429, 42901, "AI 请求额度已用完，请稍后重试", nil)
		case errors.Is(err, errAIQuotaUnavailable):
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		case operation == "moderation-feedback" && errors.Is(err, errConversationInvalid):
			respond(w, 400, 40001, "审核反馈参数错误", nil)
		case operation == "moderation-generate" && errors.Is(err, errConversationInvalid):
			respond(w, 400, 40001, "审核建议参数错误", nil)
		case operation == "group-generate" && errors.Is(err, errConversationInvalid):
			respond(w, 400, 40001, "群运营草稿参数错误", nil)
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
		case errors.Is(err, errKnowledgeConversationContext), errors.Is(err, errKnowledgeInvalid), errors.Is(err, errKnowledgeContextTooLarge):
			respond(w, 400, 40001, "知识会话上下文不可用", nil)
		case errors.Is(err, errKnowledgeProvider), errors.Is(err, errKnowledgeCitations), errors.Is(err, errKnowledgeSourceChanged), errors.Is(err, errKnowledgeAnswerInvalid), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		case errors.Is(err, errWritingUnavailable), errors.Is(err, errSkillUnavailable), errors.Is(err, errSkillConfigUnavailable), errors.Is(err, errGroupDraftUnavailable):
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		case errors.Is(err, errModerationAdviceUnavailable), errors.Is(err, errTermsAuthorityUnavailable):
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		default:
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return true
	}
	respond(w, 200, 200, "success", result)
	return true
}
func readAIConversationBody(r *http.Request) (map[string]interface{}, bool) {
	const maxBytes = 1 << 20
	raw, err := io.ReadAll(io.LimitReader(r.Body, maxBytes+1))
	if err != nil || len(raw) > maxBytes || !utf8.Valid(raw) || !validJSONSurrogates(raw) {
		return nil, false
	}
	var body map[string]interface{}
	if json.Unmarshal(raw, &body) != nil || body == nil || hasTooManyJSONMembers(raw, len(body)) {
		return nil, false
	}
	return body, true
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
