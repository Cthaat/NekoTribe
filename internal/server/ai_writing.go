package server

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

var errWritingContext = errors.New("writing context unavailable")
var errWritingUnavailable = errors.New("writing provider unavailable")

const writingSystem = "你是写作助手。根据用户提供的内容提供可审阅的草稿和修改建议；不要假装已发布或执行任何操作。"

type aiWritingStore interface {
	readAIConversation(context.Context, int64, string, moderationPolicy) (conversationRecord, error)
	listAIRecentConversationMessages(context.Context, int64, string, moderationPolicy) ([]conversationHistoryMessage, error)
	selectAIWritingSkill(context.Context, int64, string, moderationPolicy, *string) (int64, error)
	appendAIAssistantMessage(context.Context, int64, string, assistantMessageInput, moderationPolicy) (conversationMessage, error)
}

type writingRequest struct {
	SkillID          *string
	ExpectedSequence int64
}

func parseWritingRequest(raw []byte) (writingRequest, error) {
	var input writingRequest
	if len(raw) == 0 {
		return input, nil
	}
	if len(raw) > 4096 {
		return input, errConversationInvalid
	}
	data, valid := ai.DecodeScalarJSON(raw, 8)
	body, object := data.(map[string]interface{})
	if !valid || !object || len(body) > 2 || hasTooManyJSONMembers(raw, len(body)) {
		return input, errConversationInvalid
	}
	for key, value := range body {
		switch key {
		case "skill_id":
			skill, ok := value.(string)
			if !ok || skill != "writing-draft" {
				return writingRequest{}, errConversationInvalid
			}
			input.SkillID = &skill
		case "expected_sequence":
			sequence, ok := expectedAISequence(value)
			if !ok {
				return writingRequest{}, errConversationInvalid
			}
			input.ExpectedSequence = sequence
		default:
			return writingRequest{}, errConversationInvalid
		}
	}
	return input, nil
}

func generateAIWriting(ctx context.Context, store aiWritingStore, user int64, id string, policy moderationPolicy, config RefreshConfig, input writingRequest) (saved conversationMessage, runErr error) {
	if err := ctx.Err(); err != nil {
		return conversationMessage{}, errWritingUnavailable
	}
	conversation, err := store.readAIConversation(ctx, user, id, policy)
	if err != nil {
		return conversationMessage{}, err
	}
	messages, err := store.listAIRecentConversationMessages(ctx, user, id, policy)
	if err != nil {
		return conversationMessage{}, err
	}
	if conversation.Purpose != "writing" || len(messages) > 50 {
		return conversationMessage{}, errWritingContext
	}
	if input.ExpectedSequence != 0 && (len(messages) == 0 || messages[len(messages)-1].SequenceNo != input.ExpectedSequence || messages[len(messages)-1].Role != "user") {
		return conversationMessage{}, errConversationConflict
	}
	if len(messages) == 0 {
		return conversationMessage{}, errWritingContext
	}
	var previous int64
	for _, message := range messages {
		if message.SequenceNo <= previous || (message.Role != "user" && message.Role != "assistant") || message.Content == "" {
			return conversationMessage{}, errWritingContext
		}
		previous = message.SequenceNo
	}
	last := messages[len(messages)-1]
	if last.Role != "user" {
		return conversationMessage{}, errWritingContext
	}
	skillGeneration, err := store.selectAIWritingSkill(ctx, user, id, policy, input.SkillID)
	if err != nil {
		return conversationMessage{}, err
	}
	selection, resolveCredential, err := writingSelection(ctx, store, user, config)
	if err != nil {
		return conversationMessage{}, errWritingUnavailable
	}
	if selection.ConfigurationRevision > 999999999999999 {
		return conversationMessage{}, errWritingContext
	}
	audit := newAIRunAudit("writing_draft", skillGeneration)
	audit.configRevision = selection.ConfigurationRevision
	if input.SkillID != nil {
		audit.skillSelection = "explicit"
	}
	defer func() {
		if runErr != nil {
			audit.finish(ctx, nil, runErr)
		} else {
			audit.finish(ctx, &saved, nil)
		}
	}()
	budget := selection.ContextWindowTokens - selection.MaxOutputTokens - 512
	if budget > 16384 {
		budget = 16384
	}
	budget -= int64(len(writingSystem))
	selected := make([]map[string]string, 0, len(messages)+1)
	for index := len(messages) - 1; index >= 0; index-- {
		message := messages[index]
		cost := int64(len(message.Content) + 16)
		if cost > budget {
			break
		}
		budget -= cost
		selected = append(selected, map[string]string{"role": message.Role, "content": message.Content})
	}
	if len(selected) == 0 {
		return conversationMessage{}, errWritingContext
	}
	for left, right := 0, len(selected)-1; left < right; left, right = left+1, right-1 {
		selected[left], selected[right] = selected[right], selected[left]
	}
	request := append([]map[string]string{{"role": "system", "content": writingSystem}}, selected...)
	encoded, err := json.Marshal(map[string]any{"messages": request})
	if err != nil {
		return conversationMessage{}, errWritingUnavailable
	}
	transport, err := ai.NewTransport(resolveCredential)
	if err != nil {
		return conversationMessage{}, errWritingUnavailable
	}
	defer transport.CloseIdleConnections()
	audit.stage = "quota"
	if err := requireAIModelQuota(ctx, config.AIModelQuotaLimiter, user, 1); err != nil {
		return conversationMessage{}, err
	}
	audit.stage = "inference"
	answer, err := transport.Infer(ctx, selection, encoded)
	if err != nil || ctx.Err() != nil || answer.FinishReason != "stop" || len(answer.ToolCalls) != 0 || answer.Text == "" || len(answer.Text) > 65536 {
		return conversationMessage{}, errWritingUnavailable
	}
	audit.stage = "persist"
	return store.appendAIAssistantMessage(ctx, user, id, assistantMessageInput{Content: answer.Text, ExpectedSequence: last.SequenceNo, ModelID: selection.ProfileID, ModelVersion: selection.ModelVersion, ConfigRevision: selection.ConfigurationRevision, SkillGeneration: skillGeneration}, policy)
}
