package server

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestKnowledgeTurnRevalidatesAroundInference(t *testing.T) {
	source := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "公开内容", Version: strings.Repeat("a", 64)}
	candidate := knowledgeCandidate{Kind: "post", ID: 1, Version: source.Version}
	events := []string{}
	deps := knowledgeTurnDeps{
		discover: func(context.Context) ([]knowledgeSource, error) {
			events = append(events, "discover")
			return []knowledgeSource{source}, nil
		},
		hydrate: func(_ context.Context, input []knowledgeCandidate) ([]knowledgeSource, error) {
			events = append(events, "hydrate")
			if !reflect.DeepEqual(input, []knowledgeCandidate{candidate}) {
				t.Fatal(input)
			}
			return []knowledgeSource{source}, nil
		},
		infer: func(_ context.Context, input []knowledgeSource) (string, error) {
			events = append(events, "infer")
			if !reflect.DeepEqual(input, []knowledgeSource{source}) {
				t.Fatal(input)
			}
			return "answer", nil
		},
	}
	result, err := runKnowledgeTurn(context.Background(), deps)
	if err != nil || result.Answer == nil || *result.Answer != "answer" || !reflect.DeepEqual(result.Sources, []knowledgeCandidate{candidate}) || !reflect.DeepEqual(events, []string{"discover", "hydrate", "infer", "hydrate"}) {
		t.Fatal(result, err, events)
	}
}

func TestKnowledgeTurnRejectsStaleAndCancelled(t *testing.T) {
	source := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "text", Version: strings.Repeat("a", 64)}
	reads, inferences := 0, 0
	deps := knowledgeTurnDeps{
		discover: func(context.Context) ([]knowledgeSource, error) { return []knowledgeSource{source}, nil },
		hydrate: func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) {
			reads++
			if reads == 1 {
				return []knowledgeSource{source}, nil
			}
			return nil, nil
		},
		infer: func(context.Context, []knowledgeSource) (string, error) { inferences++; return "secret", nil },
	}
	if _, err := runKnowledgeTurn(context.Background(), deps); !errors.Is(err, errKnowledgeSourceChanged) {
		t.Fatal(err)
	}
	reads = 1
	inferences = 0
	result, err := runKnowledgeTurn(context.Background(), deps)
	if err != nil || result.Answer != nil || inferences != 0 {
		t.Fatal(result, err, inferences)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := runKnowledgeTurn(ctx, deps); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	deps.discover = func(context.Context) ([]knowledgeSource, error) { return []knowledgeSource{source, source}, nil }
	if _, err := runKnowledgeTurn(context.Background(), deps); !errors.Is(err, errKnowledgeInvalid) {
		t.Fatal(err)
	}
}

func TestKnowledgeTurnRejectsUnexpectedSourcesAndCancellationDuringInference(t *testing.T) {
	source := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "text", Version: strings.Repeat("a", 64)}
	deps := knowledgeTurnDeps{
		discover: func(context.Context) ([]knowledgeSource, error) { return []knowledgeSource{source}, nil },
		hydrate: func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) {
			bad := source
			bad.ID = 2
			return []knowledgeSource{bad}, nil
		},
		infer: func(context.Context, []knowledgeSource) (string, error) { return "answer", nil },
	}
	if _, err := runKnowledgeTurn(context.Background(), deps); !errors.Is(err, errKnowledgeInvalid) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	deps.hydrate = func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error) {
		return []knowledgeSource{source}, nil
	}
	deps.infer = func(context.Context, []knowledgeSource) (string, error) { cancel(); return "answer", nil }
	if _, err := runKnowledgeTurn(ctx, deps); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
