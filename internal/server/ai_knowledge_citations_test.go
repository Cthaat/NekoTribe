package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestKnowledgeCitationsValidateVerifiedReferences(t *testing.T) {
	source := knowledgeCandidate{Kind: "post", ID: 1, Version: strings.Repeat("a", 64)}
	data, _ := json.Marshal(map[string]any{"answer": "答案", "citations": []knowledgeCandidate{source}})
	result, err := parseKnowledgeAnswer(string(data), []knowledgeCandidate{source})
	if err != nil || result.Answer == nil || *result.Answer != "答案" || len(result.Sources) != 1 || result.Sources[0] != source {
		t.Fatal(result, err)
	}
	for _, value := range []any{
		map[string]any{"answer": "答案", "citations": []knowledgeCandidate{}},
		map[string]any{"answer": "答案", "citations": []knowledgeCandidate{source, source}},
		map[string]any{"answer": "答案", "citations": []knowledgeCandidate{{Kind: "post", ID: 2, Version: source.Version}}},
		map[string]any{"answer": "答案", "citations": []any{map[string]any{"kind": "post", "id": 1, "version": source.Version, "extra": true}}},
		map[string]any{"answer": "答案", "citations": []knowledgeCandidate{source}, "extra": true},
	} {
		data, _ = json.Marshal(value)
		if _, err = parseKnowledgeAnswer(string(data), []knowledgeCandidate{source}); !errors.Is(err, errKnowledgeCitations) {
			t.Fatal(string(data), err)
		}
	}
	if _, err = parseKnowledgeAnswer(fmt.Sprintf(`{"answer":"\ud800","citations":[{"kind":"post","id":1,"version":"%s"}]}`, source.Version), []knowledgeCandidate{source}); !errors.Is(err, errKnowledgeCitations) {
		t.Fatal(err)
	}
}
