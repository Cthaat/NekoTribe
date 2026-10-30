package server

import (
	"context"
	"encoding/json"
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
func TestKnowledgeHistoryRestoresMixedTermsWithoutPostID(t *testing.T) {
	post := knowledgeCandidate{Kind: "post", ID: 1, Version: strings.Repeat("a", 64)}
	terms := knowledgeCandidate{Kind: "terms", ID: 3, Version: strings.Repeat("b", 64)}
	encoded, err := encodeKnowledgeMessage("回答", []knowledgeCandidate{post, terms})
	if err != nil {
		t.Fatal(err)
	}
	rows := []knowledgeSource{{Kind: post.Kind, ID: post.ID, PostID: 1, Content: "post", Version: post.Version}, {Kind: terms.Kind, ID: terms.ID, Content: "terms", Version: terms.Version}}
	result, err := restoreKnowledgeMessage(context.Background(), encoded, func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) { return rows, nil })
	if err != nil {
		t.Fatal(err)
	}
	bytes, err := json.Marshal(result.Citations)
	var encodedCitations []map[string]any
	if err != nil || json.Unmarshal(bytes, &encodedCitations) != nil || len(encodedCitations) != 2 || encodedCitations[0]["post_id"] != float64(1) {
		t.Fatal(string(bytes), err)
	}
	if _, present := encodedCitations[1]["post_id"]; present {
		t.Fatal("terms citation has post ID", string(bytes))
	}
	rows[1].PostID = 3
	if _, err = restoreKnowledgeMessage(context.Background(), encoded, func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) { return rows, nil }); !errors.Is(err, errKnowledgeSourceChanged) {
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
func TestKnowledgeHistoryReturnsAuthorizedParentForComments(t *testing.T) {
	ref := knowledgeCandidate{Kind: "comment", ID: 23, Version: strings.Repeat("b", 64)}
	encoded, err := encodeKnowledgeMessage("回答", []knowledgeCandidate{ref})
	if err != nil {
		t.Fatal(err)
	}
	reader := func(_ context.Context, _ []knowledgeCandidate) ([]knowledgeSource, error) {
		return []knowledgeSource{{Kind: "comment", ID: 23, PostID: 99, Content: "private internal", Version: ref.Version}}, nil
	}
	result, err := restoreKnowledgeMessage(context.Background(), encoded, reader)
	if err != nil || len(result.Citations) != 1 || result.Citations[0].PostID != 99 || result.Citations[0].ID != 23 {
		t.Fatal(result, err)
	}
	raw, err := json.Marshal(result.Citations)
	if err != nil || strings.Contains(string(raw), "private internal") {
		t.Fatal(string(raw), err)
	}
	_, err = restoreKnowledgeMessage(context.Background(), encoded, func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) {
		return []knowledgeSource{{Kind: "comment", ID: 23, PostID: 0, Content: "x", Version: ref.Version}}, nil
	})
	if !errors.Is(err, errKnowledgeSourceChanged) {
		t.Fatal(err)
	}
}
