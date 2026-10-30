package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

var errKnowledgeHistory = errors.New("invalid knowledge history")

type knowledgeHistoryEnvelope struct {
	Version int                  `json:"version"`
	Answer  string               `json:"answer"`
	Sources []knowledgeCandidate `json:"sources"`
}

func encodeKnowledgeMessage(answer string, sources []knowledgeCandidate) (string, error) {
	if !utf8.ValidString(answer) || strings.TrimFunc(answer, jsTrimSpace) == "" || len(answer) > 65536 || len(sources) == 0 || validateKnowledgeCandidates(1, sources) != nil {
		return "", errKnowledgeHistory
	}
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	if encoder.Encode(knowledgeHistoryEnvelope{Version: 1, Answer: answer, Sources: sources}) != nil {
		return "", errKnowledgeHistory
	}
	encoded := strings.TrimSuffix(output.String(), "\n")
	if len(encoded) > 65536 {
		return "", errKnowledgeHistory
	}
	return encoded, nil
}
func restoreKnowledgeMessage(ctx context.Context, encoded string, hydrate func(context.Context, []knowledgeCandidate) ([]knowledgeSource, error)) (knowledgeTurnResult, error) {
	if len(encoded) > 65536 {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	value, ok := ai.DecodeScalarJSON([]byte(encoded), 4)
	if !ok {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	body, ok := value.(map[string]any)
	if !ok || len(body) != 3 || body["version"] != float64(1) {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	answer, ok := body["answer"].(string)
	if !ok {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	raw, ok := body["sources"].([]any)
	if !ok || len(raw) == 0 || len(raw) > 20 {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	packed, err := json.Marshal(map[string]any{"answer": answer, "citations": raw})
	if err != nil {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	// Validate exact citation shape and scalar IDs before accepting stored references.
	var candidates []knowledgeCandidate
	for _, item := range raw {
		object, valid := item.(map[string]any)
		if !valid || len(object) != 3 {
			return knowledgeTurnResult{}, errKnowledgeHistory
		}
		kind, kindOK := object["kind"].(string)
		version, versionOK := object["version"].(string)
		id, idOK := object["id"].(float64)
		if !kindOK || !versionOK || !idOK || id < 1 || id > float64(knowledgeMaxID) || math.Trunc(id) != id {
			return knowledgeTurnResult{}, errKnowledgeHistory
		}
		candidates = append(candidates, knowledgeCandidate{Kind: kind, ID: int64(id), Version: version})
	}
	if validateKnowledgeCandidates(1, candidates) != nil {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	message, err := parseKnowledgeAnswer(string(packed), candidates)
	if err != nil {
		return knowledgeTurnResult{}, errKnowledgeHistory
	}
	rows, err := hydrate(ctx, append([]knowledgeCandidate(nil), message.Sources...))
	if err != nil {
		return knowledgeTurnResult{}, err
	}
	if len(rows) != len(message.Sources) || checkKnowledgeRows(message.Sources, rows) != nil {
		return knowledgeTurnResult{}, errKnowledgeSourceChanged
	}
	return message, nil
}
