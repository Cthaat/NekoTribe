package server

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestSelectKnowledgeContextHistoryAndSources(t *testing.T) {
	ref := knowledgeCitation{Kind: "post", ID: 1, PostID: 1, Version: strings.Repeat("a", 64)}
	messages := []conversationHistoryMessage{{SequenceNo: 1, Role: "user", Content: "之前的问题"}, {SequenceNo: 2, Role: "assistant", Content: "之前的回答", Citations: []knowledgeCitation{ref}}, {SequenceNo: 3, Role: "user", Content: "新的问题"}}
	selected, err := selectKnowledgeContext(messages, 10000, 20)
	if err != nil || selected.Question != "新的问题" || !reflect.DeepEqual(selected.History, []knowledgeModelMessage{{Role: "user", Content: "之前的问题"}, {Role: "assistant", Content: "之前的回答"}}) || !reflect.DeepEqual(selected.Sources, []knowledgeCandidate{{Kind: "post", ID: 1, Version: ref.Version}}) {
		t.Fatalf("unexpected selection: %#v, %v", selected, err)
	}
	messages[1].Citations[0].Version = strings.Repeat("b", 64)
	if selected.Snapshot[1].Citations[0].Version != ref.Version {
		t.Fatal("snapshot aliases input citations")
	}
}

func TestSelectKnowledgeContextLimitsAndInvalidHistory(t *testing.T) {
	ref := knowledgeCitation{Kind: "post", ID: 1, PostID: 1, Version: strings.Repeat("a", 64)}
	messages := []conversationHistoryMessage{{SequenceNo: 1, Role: "assistant", Content: "older", Citations: []knowledgeCitation{ref}}, {SequenceNo: 2, Role: "user", Content: "\"\\猫\u2028"}}
	selected, err := selectKnowledgeContext(messages, 10000, 0)
	if err != nil || len(selected.History) != 0 || len(selected.Sources) != 0 || selected.Question != messages[1].Content {
		t.Fatalf("unexpected truncation: %#v %v", selected, err)
	}
	// JSON.stringify({question,history:[]}) is 38 UTF-8 bytes for this input.
	if _, err = selectKnowledgeContext(messages, 37, 20); !errors.Is(err, errKnowledgeContextTooLarge) {
		t.Fatalf("budget: %v", err)
	}
	if result, err := selectKnowledgeContext(messages, 38, 20); err != nil || len(result.History) != 0 {
		t.Fatalf("budget boundary: %#v %v", result, err)
	}
	messages[0].Citations = nil
	if _, err = selectKnowledgeContext(messages, 10000, 20); !errors.Is(err, errKnowledgeConversationContext) {
		t.Fatalf("missing citations: %v", err)
	}
	messages[0].Citations = []knowledgeCitation{ref, ref}
	if _, err = selectKnowledgeContext(messages, 10000, 20); !errors.Is(err, errKnowledgeConversationContext) {
		t.Fatalf("duplicate citations: %v", err)
	}
}

func TestSelectKnowledgeContextRejectsChangedVersionAndTrimsOldest(t *testing.T) {
	ref := knowledgeCitation{Kind: "post", ID: 1, PostID: 1, Version: strings.Repeat("a", 64)}
	changed := ref
	changed.Version = strings.Repeat("b", 64)
	messages := []conversationHistoryMessage{
		{SequenceNo: 1, Role: "assistant", Content: "old", Citations: []knowledgeCitation{ref}},
		{SequenceNo: 2, Role: "assistant", Content: "recent", Citations: []knowledgeCitation{changed}},
		{SequenceNo: 3, Role: "user", Content: "question"},
	}
	if _, err := selectKnowledgeContext(messages, 10000, 20); !errors.Is(err, errKnowledgeConversationContext) {
		t.Fatalf("changed version: %v", err)
	}
	messages[0].Citations[0] = knowledgeCitation{Kind: "comment", ID: 2, PostID: 1, Version: ref.Version}
	selected, err := selectKnowledgeContext(messages, 10000, 1)
	if err != nil || len(selected.History) != 1 || selected.History[0].Content != "recent" || len(selected.Snapshot) != 2 || selected.Snapshot[0].SequenceNo != 2 {
		t.Fatalf("source limit: %#v, %v", selected, err)
	}
}
