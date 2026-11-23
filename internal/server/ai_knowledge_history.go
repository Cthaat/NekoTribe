package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

var errKnowledgeHistory = errors.New("invalid knowledge history")

type knowledgeHistoryEnvelope struct {
	Version      int                  `json:"version"`
	Answer       string               `json:"answer"`
	Sources      []knowledgeCandidate `json:"sources"`
	Dependencies []knowledgeCandidate `json:"dependencies,omitempty"`
}

func encodeKnowledgeMessage(answer string, sources []knowledgeCandidate) (string, error) {
	return encodeKnowledgeMessageWithDependencies(answer, sources, nil)
}

func encodeKnowledgeMessageWithDependencies(answer string, sources, dependencies []knowledgeCandidate) (string, error) {
	if !utf8.ValidString(answer) || strings.TrimFunc(answer, jsTrimSpace) == "" || len(answer) > 65536 || len(sources) == 0 || validateKnowledgeCandidates(1, sources) != nil {
		return "", errKnowledgeHistory
	}
	version := 1
	if len(dependencies) > 0 {
		if validateKnowledgeCandidates(1, dependencies) != nil || !knowledgeContainsReferences(dependencies, sources) {
			return "", errKnowledgeHistory
		}
		version = 2
	}
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	if encoder.Encode(knowledgeHistoryEnvelope{Version: version, Answer: answer, Sources: sources, Dependencies: dependencies}) != nil {
		return "", errKnowledgeHistory
	}
	encoded := strings.TrimSuffix(output.String(), "\n")
	if len(encoded) > 65536 {
		return "", errKnowledgeHistory
	}
	return encoded, nil
}

func knowledgeContainsReferences(all, required []knowledgeCandidate) bool {
	for _, ref := range required {
		if !slices.Contains(all, ref) {
			return false
		}
	}
	return true
}

type knowledgeCitation struct {
	Kind    string `json:"kind"`
	ID      int64  `json:"id"`
	Version string `json:"version"`
	PostID  int64  `json:"post_id,omitempty"`
	GroupID int64  `json:"group_id,omitempty"`
}
type knowledgeRestored struct {
	knowledgeTurnResult
	Citations []knowledgeCitation
}

func restoreKnowledgeMessage(ctx context.Context, encoded string, hydrate func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error)) (knowledgeRestored, error) {
	if len(encoded) > 65536 {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	value, ok := ai.DecodeScalarJSON([]byte(encoded), 4)
	if !ok {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	body, ok := value.(map[string]any)
	if !ok {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	var dependencies []knowledgeCandidate
	switch body["version"] {
	case float64(1):
		if len(body) != 3 {
			return knowledgeRestored{}, errKnowledgeHistory
		}
	case float64(2):
		if len(body) != 4 {
			return knowledgeRestored{}, errKnowledgeHistory
		}
		dependencies = decodeKnowledgeReferences(body["dependencies"])
		if len(dependencies) == 0 {
			return knowledgeRestored{}, errKnowledgeHistory
		}
	default:
		return knowledgeRestored{}, errKnowledgeHistory
	}
	answer, ok := body["answer"].(string)
	if !ok {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	candidates := decodeKnowledgeReferences(body["sources"])
	if len(candidates) == 0 {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	packed, err := json.Marshal(map[string]any{"answer": answer, "citations": candidates})
	if err != nil {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	message, err := parseKnowledgeAnswer(string(packed), candidates)
	if err != nil {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	refs := message.Sources
	if len(dependencies) > 0 {
		if !knowledgeContainsReferences(dependencies, refs) {
			return knowledgeRestored{}, errKnowledgeHistory
		}
		refs = dependencies
	}
	rows, err := hydrate(ctx, slices.Clone(refs))
	if err != nil {
		return knowledgeRestored{}, err
	}
	if len(rows) != len(refs) || checkKnowledgeRows(refs, rows) != nil {
		return knowledgeRestored{}, errKnowledgeSourceChanged
	}
	byKey := make(map[string]knowledgeSource, len(rows))
	for _, row := range rows {
		if !validKnowledgeLocation(row.Kind, row.ID, row.PostID, row.GroupID) {
			return knowledgeRestored{}, errKnowledgeSourceChanged
		}
		byKey[knowledgeKey(row.Kind, row.ID)] = row
	}
	citations := make([]knowledgeCitation, 0, len(message.Sources))
	for _, ref := range message.Sources {
		row := byKey[knowledgeKey(ref.Kind, ref.ID)]
		citations = append(citations, knowledgeCitation{Kind: ref.Kind, ID: ref.ID, Version: ref.Version, PostID: row.PostID, GroupID: row.GroupID})
	}
	message.Dependencies = dependencies
	return knowledgeRestored{knowledgeTurnResult: message, Citations: citations}, nil
}

func decodeKnowledgeReferences(value any) []knowledgeCandidate {
	raw, ok := value.([]any)
	if !ok || len(raw) == 0 || len(raw) > 20 {
		return nil
	}
	refs := make([]knowledgeCandidate, 0, len(raw))
	for _, item := range raw {
		object, valid := item.(map[string]any)
		if !valid || len(object) != 3 {
			return nil
		}
		kind, kindOK := object["kind"].(string)
		version, versionOK := object["version"].(string)
		id, idOK := object["id"].(float64)
		if !kindOK || !versionOK || !idOK || id < 1 || id > float64(knowledgeMaxID) || math.Trunc(id) != id {
			return nil
		}
		refs = append(refs, knowledgeCandidate{Kind: kind, ID: int64(id), Version: version})
	}
	if validateKnowledgeCandidates(1, refs) != nil {
		return nil
	}
	return refs
}
