package server

import (
	"context"
	"errors"
	"fmt"
	"unicode/utf8"
)

var errKnowledgeSourceChanged = errors.New("knowledge source changed")
var errKnowledgeAnswerInvalid = errors.New("invalid knowledge answer")

type knowledgeTurnDeps struct {
	discover func(context.Context) ([]knowledgeSource, error)
	hydrate  func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error)
	infer    func(context.Context, []knowledgeSource) (string, error)
}
type knowledgeTurnResult struct {
	Answer  *string
	Sources []knowledgeCandidate
}

func knowledgeCandidates(rows []knowledgeSource) []knowledgeCandidate {
	result := make([]knowledgeCandidate, 0, len(rows))
	for _, row := range rows {
		result = append(result, knowledgeCandidate{Kind: row.Kind, ID: row.ID, Version: row.Version})
	}
	return result
}
func knowledgeKey(kind string, id int64) string { return fmt.Sprintf("%s:%d", kind, id) }
func checkKnowledgeRows(candidates []knowledgeCandidate, rows []knowledgeSource) error {
	if len(rows) > len(candidates) {
		return errKnowledgeInvalid
	}
	expected := make(map[string]string, len(candidates))
	for _, candidate := range candidates {
		expected[knowledgeKey(candidate.Kind, candidate.ID)] = candidate.Version
	}
	seen := make(map[string]bool, len(rows))
	for _, row := range rows {
		key := knowledgeKey(row.Kind, row.ID)
		version, ok := expected[key]
		if !ok || seen[key] || version != row.Version {
			return errKnowledgeInvalid
		}
		seen[key] = true
	}
	return nil
}

// Internal boundary; callers authenticate and release database connections before inference.
func runKnowledgeTurn(ctx context.Context, deps knowledgeTurnDeps) (knowledgeTurnResult, error) {
	empty := knowledgeTurnResult{Sources: []knowledgeCandidate{}}
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	discovered, err := deps.discover(ctx)
	if err != nil {
		return empty, err
	}
	if err = ctx.Err(); err != nil {
		return empty, err
	}
	candidates := knowledgeCandidates(discovered)
	if err = validateKnowledgeCandidates(1, candidates); err != nil {
		return empty, err
	}
	sources, err := deps.hydrate(ctx, append([]knowledgeCandidate(nil), candidates...))
	if err != nil {
		return empty, err
	}
	if err = checkKnowledgeRows(candidates, sources); err != nil {
		return empty, err
	}
	if err = ctx.Err(); err != nil {
		return empty, err
	}
	if len(sources) == 0 {
		return empty, nil
	}
	sources = append([]knowledgeSource(nil), sources...)
	used := knowledgeCandidates(sources)
	answer, err := deps.infer(ctx, append([]knowledgeSource(nil), sources...))
	if err != nil {
		return empty, err
	}
	if err = ctx.Err(); err != nil {
		return empty, err
	}
	if answer == "" || len(answer) > 65536 || !utf8.ValidString(answer) {
		return empty, errKnowledgeAnswerInvalid
	}
	after, err := deps.hydrate(ctx, append([]knowledgeCandidate(nil), used...))
	if err != nil {
		return empty, err
	}
	if err = checkKnowledgeRows(used, after); err != nil {
		return empty, err
	}
	if err = ctx.Err(); err != nil {
		return empty, err
	}
	current := make(map[string]knowledgeSource, len(after))
	for _, row := range after {
		current[knowledgeKey(row.Kind, row.ID)] = row
	}
	if len(after) != len(sources) {
		return empty, errKnowledgeSourceChanged
	}
	for _, row := range sources {
		currentRow, ok := current[knowledgeKey(row.Kind, row.ID)]
		if !ok || currentRow.PostID != row.PostID || currentRow.Content != row.Content {
			return empty, errKnowledgeSourceChanged
		}
	}
	return knowledgeTurnResult{Answer: &answer, Sources: used}, nil
}
