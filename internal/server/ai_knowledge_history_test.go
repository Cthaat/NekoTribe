package server

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestKnowledgeHistoryRestoresOnlyCurrentSources(t *testing.T) {
	ref := knowledgeCandidate{Kind: "post", ID: 1, Version: strings.Repeat("a", 64)}
	encoded, err := encodeKnowledgeMessage("答案", []knowledgeCandidate{ref})
	if err != nil {
		t.Fatal(err)
	}
	reader := func(_ context.Context, refs []knowledgeCandidate) ([]knowledgeSource, error) {
		if len(refs) != 1 || refs[0] != ref {
			t.Fatal(refs)
		}
		return []knowledgeSource{{Kind: "post", ID: 1, PostID: 1, Content: "public", Version: ref.Version}}, nil
	}
	result, err := restoreKnowledgeMessage(context.Background(), encoded, reader)
	if err != nil || result.Answer == nil || *result.Answer != "答案" || len(result.Sources) != 1 || result.Sources[0] != ref {
		t.Fatal(result, err)
	}
	_, err = restoreKnowledgeMessage(context.Background(), encoded, func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) { return nil, nil })
	if !errors.Is(err, errKnowledgeSourceChanged) {
		t.Fatal(err)
	}
}
func TestKnowledgeHistoryRejectsInvalidAndOversize(t *testing.T) {
	ref := knowledgeCandidate{Kind: "post", ID: 1, Version: strings.Repeat("a", 64)}
	if _, err := encodeKnowledgeMessage("text", []knowledgeCandidate{ref, ref}); !errors.Is(err, errKnowledgeHistory) {
		t.Fatal(err)
	}
	if _, err := encodeKnowledgeMessage(strings.Repeat("x", 65536), []knowledgeCandidate{ref}); !errors.Is(err, errKnowledgeHistory) {
		t.Fatal(err)
	}
	called := false
	_, err := restoreKnowledgeMessage(context.Background(), `{"version":1,"answer":"x","sources":[]}`, func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) { called = true; return nil, nil })
	if !errors.Is(err, errKnowledgeHistory) || called {
		t.Fatal(err, called)
	}
}
