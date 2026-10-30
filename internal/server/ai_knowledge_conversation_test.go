package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type knowledgeConversationFake struct {
	knowledgeServiceFake
	purpose   string
	messages  []conversationHistoryMessage
	saved     assistantMessageInput
	refs      []knowledgeCandidate
	appendErr error
}

func TestKnowledgeConversationUsesAndGuardsHistory(t *testing.T) {
	ref := knowledgeCandidate{Kind: "post", ID: 1, Version: strings.Repeat("a", 64)}
	store := &knowledgeConversationFake{knowledgeServiceFake: knowledgeServiceFake{rows: []knowledgeSource{{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: ref.Version}}}, purpose: "knowledge", messages: []conversationHistoryMessage{{SequenceNo: 1, Role: "assistant", Content: "旧回答", Citations: []knowledgeCitation{{Kind: "post", ID: 1, PostID: 1, Version: ref.Version}}}, {SequenceNo: 2, Role: "user", Content: "猫"}}}
	transport := &knowledgeTransportFake{store: &store.knowledgeServiceFake}
	selection := ai.Selection{Role: "knowledge", ProfileID: "profile", ConfigurationRevision: 3, ContextWindowTokens: 8192, MaxOutputTokens: 512}
	if _, err := generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport); err != nil {
		t.Fatal(err)
	}
	var request struct {
		Messages []struct {
			Content string `json:"content"`
		} `json:"messages"`
	}
	var payload struct {
		History []knowledgeModelMessage `json:"history"`
	}
	if json.Unmarshal(transport.input, &request) != nil || len(request.Messages) != 2 || json.Unmarshal([]byte(request.Messages[1].Content), &payload) != nil || len(payload.History) != 1 || payload.History[0].Content != "旧回答" {
		t.Fatal("history not passed to model", string(transport.input))
	}
	if len(store.saved.ContextSnapshot) != 2 || store.saved.ContextSnapshot[0].Content != "旧回答" || len(store.refs) != 1 || store.refs[0] != ref {
		t.Fatal("history or dependencies not guarded", store.saved, store.refs)
	}
}

func TestKnowledgeConversationPreservesAndRechecksHistoricalSources(t *testing.T) {
	newRef := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: strings.Repeat("a", 64)}
	old := knowledgeSource{Kind: "comment", ID: 2, PostID: 1, Content: "旧资料", Version: strings.Repeat("b", 64)}
	store := &knowledgeConversationFake{knowledgeServiceFake: knowledgeServiceFake{rows: []knowledgeSource{newRef}, historical: []knowledgeSource{old}}, purpose: "knowledge", messages: []conversationHistoryMessage{{SequenceNo: 1, Role: "assistant", Content: "旧回答", Citations: []knowledgeCitation{{Kind: old.Kind, ID: old.ID, PostID: old.PostID, Version: old.Version}}}, {SequenceNo: 2, Role: "user", Content: "猫"}}}
	transport := &knowledgeTransportFake{store: &store.knowledgeServiceFake}
	selection := ai.Selection{Role: "knowledge", ProfileID: "profile", ConfigurationRevision: 3, ContextWindowTokens: 8192, MaxOutputTokens: 512}
	if _, err := generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport); err != nil {
		t.Fatal(err)
	}
	if len(store.refs) != 2 || store.refs[1] != (knowledgeCandidate{Kind: old.Kind, ID: old.ID, Version: old.Version}) {
		t.Fatal("historical source missing", store.refs)
	}
	store.events = nil
	transport.revoke = true
	if _, err := generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport); !errors.Is(err, errKnowledgeSourceChanged) || strings.Contains(strings.Join(store.events, ","), "append") {
		t.Fatal("revoked history was delivered", err, store.events)
	}
}

func TestKnowledgeConversationSeparatesSearchPhraseFromQuestion(t *testing.T) {
	store := &knowledgeConversationFake{knowledgeServiceFake: knowledgeServiceFake{rows: []knowledgeSource{{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: strings.Repeat("a", 64)}}}, purpose: "knowledge", messages: []conversationHistoryMessage{{SequenceNo: 1, Role: "user", Content: "社区里有哪些猫咪？"}}}
	transport := &knowledgeTransportFake{store: &store.knowledgeServiceFake}
	selection := ai.Selection{Role: "knowledge", ProfileID: "profile", ConfigurationRevision: 3, ContextWindowTokens: 8192, MaxOutputTokens: 512}
	_, err := generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport, "猫")
	if err != nil {
		t.Fatal(err)
	}
	var request struct {
		Messages []struct {
			Content string `json:"content"`
		} `json:"messages"`
	}
	if err = json.Unmarshal(transport.input, &request); err != nil || len(request.Messages) != 2 {
		t.Fatal(err)
	}
	var data struct {
		Question string `json:"question"`
	}
	if err = json.Unmarshal([]byte(request.Messages[1].Content), &data); err != nil || data.Question != "社区里有哪些猫咪？" {
		t.Fatal(data, err)
	}
}

func (f *knowledgeConversationFake) readAIConversation(context.Context, int64, string, moderationPolicy) (conversationRecord, error) {
	f.events = append(f.events, "read")
	return conversationRecord{Purpose: f.purpose}, nil
}
func (f *knowledgeConversationFake) listAIRecentConversationMessages(context.Context, int64, string, moderationPolicy) ([]conversationHistoryMessage, error) {
	f.events = append(f.events, "history")
	return f.messages, nil
}
func (f *knowledgeConversationFake) appendAIKnowledgeAssistantMessage(_ context.Context, _ int64, _ string, input assistantMessageInput, refs []knowledgeCandidate, _ moderationPolicy) (conversationMessage, error) {
	f.events = append(f.events, "append")
	f.saved = input
	f.refs = refs
	if f.appendErr != nil {
		return conversationMessage{}, f.appendErr
	}
	return conversationMessage{SequenceNo: 2}, nil
}

func TestKnowledgeConversationDoesNotHideConcurrentConflictOrCancellation(t *testing.T) {
	ref := knowledgeCandidate{Kind: "post", ID: 1, Version: strings.Repeat("a", 64)}
	store := &knowledgeConversationFake{knowledgeServiceFake: knowledgeServiceFake{rows: []knowledgeSource{{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: ref.Version}}}, purpose: "knowledge", messages: []conversationHistoryMessage{{SequenceNo: 1, Role: "user", Content: "猫"}}, appendErr: errConversationConflict}
	transport := &knowledgeTransportFake{store: &store.knowledgeServiceFake}
	selection := ai.Selection{Role: "knowledge", ProfileID: "profile", ConfigurationRevision: 3, ContextWindowTokens: 8192, MaxOutputTokens: 512}
	if _, err := generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport); !errors.Is(err, errConversationConflict) {
		t.Fatal(err)
	}
	store.events = nil
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := generateKnowledgeConversationWithTransport(ctx, store, 42, "id", moderationPolicy{}, selection, transport); !errors.Is(err, context.Canceled) || len(store.events) != 0 {
		t.Fatal(err, store.events)
	}
}

func TestKnowledgeConversationGeneratesAndPersists(t *testing.T) {
	ref := knowledgeCandidate{Kind: "post", ID: 1, Version: strings.Repeat("a", 64)}
	store := &knowledgeConversationFake{knowledgeServiceFake: knowledgeServiceFake{rows: []knowledgeSource{{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: ref.Version}}}, purpose: "knowledge", messages: []conversationHistoryMessage{{SequenceNo: 1, Role: "user", Content: "猫"}}}
	transport := &knowledgeTransportFake{store: &store.knowledgeServiceFake}
	selection := ai.Selection{Role: "knowledge", ProfileID: "profile", ConfigurationRevision: 3, ContextWindowTokens: 8192, MaxOutputTokens: 512}
	message, err := generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport)
	if err != nil || message == nil || message.SequenceNo != 2 || strings.Join(store.events, ",") != "read,history,discover,hydrate,infer,hydrate,append" || store.saved.Content != "answer" || store.saved.ExpectedSequence != 1 || store.saved.ModelID != "profile" || store.saved.ConfigRevision != 3 || len(store.refs) != 1 || store.refs[0] != ref {
		t.Fatal(message, err, store)
	}
}
func TestKnowledgeConversationNoEvidenceAndInvalidContext(t *testing.T) {
	store := &knowledgeConversationFake{purpose: "knowledge", messages: []conversationHistoryMessage{{SequenceNo: 1, Role: "user", Content: "猫"}}}
	transport := &knowledgeTransportFake{store: &store.knowledgeServiceFake}
	selection := ai.Selection{Role: "knowledge", ProfileID: "profile", ConfigurationRevision: 3, ContextWindowTokens: 8192, MaxOutputTokens: 512}
	message, err := generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport)
	if err != nil || message != nil || strings.Contains(strings.Join(store.events, ","), "append") {
		t.Fatal(message, err, store.events)
	}
	store.purpose = "writing"
	if _, err = generateKnowledgeConversationWithTransport(context.Background(), store, 42, "id", moderationPolicy{}, selection, transport); !errors.Is(err, errKnowledgeConversationContext) {
		t.Fatal(err)
	}
}
