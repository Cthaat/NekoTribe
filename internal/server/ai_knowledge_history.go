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

type knowledgeCitation struct {
	Kind    string `json:"kind"`
	ID      int64  `json:"id"`
	Version string `json:"version"`
	PostID  int64  `json:"post_id"`
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
	if !ok || len(body) != 3 || body["version"] != float64(1) {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	answer, ok := body["answer"].(string)
	if !ok {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	raw, ok := body["sources"].([]any)
	if !ok || len(raw) == 0 || len(raw) > 20 {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	packed, err := json.Marshal(map[string]any{"answer": answer, "citations": raw})
	if err != nil {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	// Validate exact citation shape and scalar IDs before accepting stored references.
	var candidates []knowledgeCandidate
	for _, item := range raw {
		object, valid := item.(map[string]any)
		if !valid || len(object) != 3 {
			return knowledgeRestored{}, errKnowledgeHistory
		}
		kind, kindOK := object["kind"].(string)
		version, versionOK := object["version"].(string)
		id, idOK := object["id"].(float64)
		if !kindOK || !versionOK || !idOK || id < 1 || id > float64(knowledgeMaxID) || math.Trunc(id) != id {
			return knowledgeRestored{}, errKnowledgeHistory
		}
		candidates = append(candidates, knowledgeCandidate{Kind: kind, ID: int64(id), Version: version})
	}
	if validateKnowledgeCandidates(1, candidates) != nil {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	message, err := parseKnowledgeAnswer(string(packed), candidates)
	if err != nil {
		return knowledgeRestored{}, errKnowledgeHistory
	}
	rows, err := hydrate(ctx, append([]knowledgeCandidate(nil), message.Sources...))
	if err != nil {
		return knowledgeRestored{}, err
	}
	if len(rows) != len(message.Sources) || checkKnowledgeRows(message.Sources, rows) != nil {
		return knowledgeRestored{}, errKnowledgeSourceChanged
	}
	byKey := make(map[string]knowledgeSource, len(rows))
	for _, row := range rows {
		if !validKnowledgeID(row.PostID) || (row.Kind == "post" && row.PostID != row.ID) {
			return knowledgeRestored{}, errKnowledgeSourceChanged
		}
		byKey[knowledgeKey(row.Kind, row.ID)] = row
	}
	citations := make([]knowledgeCitation, 0, len(message.Sources))
	for _, ref := range message.Sources {
		row := byKey[knowledgeKey(ref.Kind, ref.ID)]
		citations = append(citations, knowledgeCitation{Kind: ref.Kind, ID: ref.ID, Version: ref.Version, PostID: row.PostID})
	}
	return knowledgeRestored{knowledgeTurnResult: message, Citations: citations}, nil
}
