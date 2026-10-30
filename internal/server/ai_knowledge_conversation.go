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
	appendAIKnowledgeAssistantMessage(context.Context, int64, string, assistantMessageInput, []knowledgeCandidate, moderationPolicy) (conversationMessage, error)
}

// Store calls finish before inference; no database transaction spans the model request.
func generateKnowledgeConversationWithTransport(ctx context.Context, store knowledgeConversationStore, user int64, id string, policy moderationPolicy, selection ai.Selection, transport knowledgeTransport, searchPhrase ...string) (*conversationMessage, error) {
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
	if conversation.Purpose != "knowledge" || len(messages) == 0 || len(messages) > 50 {
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
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	result, err := generateKnowledgeWithTransport(ctx, store, user, last.Content, selection, transport, searchPhrase...)
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if result.Answer == nil {
		return nil, nil
	}
	message, err := store.appendAIKnowledgeAssistantMessage(ctx, user, id, assistantMessageInput{Content: *result.Answer, ExpectedSequence: last.SequenceNo, ModelID: selection.ProfileID, ConfigRevision: selection.ConfigurationRevision}, result.Sources, policy)
	if err != nil {
		return nil, err
	}
	return &message, nil
}

// The caller authenticates the user and obtains configuration from the server environment.
func generateKnowledgeConversation(ctx context.Context, store knowledgeConversationStore, user int64, id string, policy moderationPolicy, config RefreshConfig, searchPhrase ...string) (*conversationMessage, error) {
	if config.AIModelConfig == "" || len(config.AIModelConfig) > 65536 {
		return nil, errKnowledgeProvider
	}
	router, err := ai.NewModelRouter([]byte(config.AIModelConfig))
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
	return generateKnowledgeConversationWithTransport(ctx, store, user, id, policy, selection, transport, searchPhrase...)
}
