package server

import (
	"context"
	"errors"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

var errKnowledgeConversationContext = errors.New("knowledge conversation context unavailable")

type knowledgeConversationStore interface {
	knowledgeServiceStore
	readAIConversation(context.Context, int64, string, moderationPolicy) (conversationRecord, error)
	listAIRecentConversationMessages(context.Context, int64, string, moderationPolicy) ([]conversationHistoryMessage, error)
	selectAIKnowledgeSkill(context.Context, int64, string, moderationPolicy, *string) (int64, error)
	appendAIKnowledgeAssistantMessage(context.Context, int64, string, assistantMessageInput, []knowledgeCandidate, moderationPolicy) (conversationMessage, error)
}

// Store calls finish before inference; no database transaction spans the model request.
func generateKnowledgeConversationWithTransport(ctx context.Context, store knowledgeConversationStore, user int64, id string, policy moderationPolicy, selection ai.Selection, transport knowledgeTransport, input knowledgeSearchBody) (saved *conversationMessage, runErr error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if user <= 0 || user > 9007199254740991 || selection.Role != "knowledge" || !aiProfileID.MatchString(selection.ProfileID) || selection.ConfigurationRevision < 1 || selection.ConfigurationRevision > 999999999999999 {
		return nil, errKnowledgeConversationContext
	}
	conversation, err := store.readAIConversation(ctx, user, id, policy)
	if err != nil {
		return nil, err
	}
	messages, err := store.listAIRecentConversationMessages(ctx, user, id, policy)
	if err != nil {
		return nil, err
	}
	if conversation.Purpose != "knowledge" || len(messages) > 50 {
		return nil, errKnowledgeConversationContext
	}
	evidenceStore := knowledgeServiceStore(store)
	if conversation.KnowledgeScope.restricted() {
		scoped, ok := store.(scopedKnowledgeStore)
		if !ok {
			return nil, errKnowledgeConversationContext
		}
		evidenceStore = scoped.knowledgeStoreForConversation(conversation.access())
	}
	if input.ExpectedSequence != 0 && (len(messages) == 0 || messages[len(messages)-1].SequenceNo != input.ExpectedSequence || messages[len(messages)-1].Role != "user") {
		return nil, errConversationConflict
	}
	if len(messages) == 0 {
		return nil, errKnowledgeConversationContext
	}
	var previous int64
	for _, message := range messages {
		if message.SequenceNo <= previous || message.SequenceNo > 9999999999 || (message.Role != "user" && message.Role != "assistant") || message.Content == "" || !utf8.ValidString(message.Content) {
			return nil, errKnowledgeConversationContext
		}
		previous = message.SequenceNo
	}
	last := messages[len(messages)-1]
	if last.Role != "user" {
		return nil, errKnowledgeConversationContext
	}
	skillGeneration, err := store.selectAIKnowledgeSkill(ctx, user, id, policy, input.SkillID)
	if err != nil {
		return nil, err
	}
	audit := newAIRunAudit("knowledge_answer", skillGeneration)
	audit.configRevision = selection.ConfigurationRevision
	if input.SkillID != nil {
		audit.skillSelection = "explicit"
	}
	defer func() { audit.finish(ctx, saved, runErr) }()
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	var phrases []string
	if input.Phrase != nil {
		phrases = []string{*input.Phrase}
	}
	audit.stage = "evidence"
	result, selected, err := generateScopedKnowledgeWithHistory(ctx, evidenceStore, user, last.Content, selection, transport, messages, conversation.KnowledgeScope, phrases...)
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if result.Answer == nil {
		return nil, nil
	}
	audit.stage = "persist"
	message, err := store.appendAIKnowledgeAssistantMessage(ctx, user, id, assistantMessageInput{Content: *result.Answer, ExpectedSequence: last.SequenceNo, ModelID: selection.ProfileID, ModelVersion: selection.ModelVersion, ConfigRevision: selection.ConfigurationRevision, SkillGeneration: skillGeneration, ContextSnapshot: selected.Snapshot, KnowledgeDependencies: result.Dependencies}, result.Sources, policy)
	if err != nil {
		return nil, err
	}
	return &message, nil
}

// The caller authenticates the user and obtains configuration from the server environment.
func generateKnowledgeConversation(ctx context.Context, store knowledgeConversationStore, user int64, id string, policy moderationPolicy, config RefreshConfig, input knowledgeSearchBody) (*conversationMessage, error) {
	router, err := config.modelRouter()
	if err != nil {
		return nil, errKnowledgeProvider
	}
	selection, err := router.Select("knowledge", nil)
	if err != nil {
		return nil, errKnowledgeProvider
	}
	transport, err := ai.NewTransport(config.aiCredential)
	if err != nil {
		return nil, errKnowledgeProvider
	}
	defer transport.CloseIdleConnections()
	return generateKnowledgeConversationWithTransport(ctx, store, user, id, policy, selection, quotaKnowledgeTransport{
		knowledgeTransport: transport, limiter: config.AIModelQuotaLimiter, actor: user,
	}, input)
}
