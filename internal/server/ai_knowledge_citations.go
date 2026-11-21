package server

import (
	"errors"
	"math"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

var errKnowledgeCitations = errors.New("invalid knowledge citations")

func parseKnowledgeAnswer(text string, verified []knowledgeCandidate) (knowledgeTurnResult, error) {
	return parseKnowledgeCitations(text, verified, false)
}

func parseKnowledgeCitations(text string, verified []knowledgeCandidate, numbered bool) (knowledgeTurnResult, error) {
	value, ok := ai.DecodeScalarJSON([]byte(text), 4)
	if !ok {
		return knowledgeTurnResult{}, errKnowledgeCitations
	}
	object, ok := value.(map[string]any)
	if !ok || len(object) != 2 {
		return knowledgeTurnResult{}, errKnowledgeCitations
	}
	answer, ok := object["answer"].(string)
	if !ok || strings.TrimFunc(answer, jsTrimSpace) == "" || len(answer) > 65536 {
		return knowledgeTurnResult{}, errKnowledgeCitations
	}
	citations, ok := object["citations"].([]any)
	if !ok || len(citations) < 1 || len(citations) > 20 {
		return knowledgeTurnResult{}, errKnowledgeCitations
	}
	allowed := make(map[knowledgeCandidate]bool, len(verified))
	for _, candidate := range verified {
		allowed[candidate] = true
	}
	seen := make(map[knowledgeCandidate]bool, len(citations))
	result := make([]knowledgeCandidate, 0, len(citations))
	for _, raw := range citations {
		var candidate knowledgeCandidate
		if numbered {
			reference, ok := raw.(float64)
			if !ok || reference < 1 || reference > float64(len(verified)) || math.Trunc(reference) != reference {
				return knowledgeTurnResult{}, errKnowledgeCitations
			}
			candidate = verified[int(reference)-1]
		} else {
			item, ok := raw.(map[string]any)
			if !ok || len(item) != 3 {
				return knowledgeTurnResult{}, errKnowledgeCitations
			}
			kind, kindOK := item["kind"].(string)
			version, versionOK := item["version"].(string)
			id, idOK := item["id"].(float64)
			if !kindOK || !versionOK || !idOK || (kind != "post" && kind != "comment" && kind != "terms" && !isGroupKnowledgeKind(kind)) || id < 1 || id > float64(knowledgeMaxID) || (kind == "terms" && id > 8) || math.Trunc(id) != id {
				return knowledgeTurnResult{}, errKnowledgeCitations
			}
			candidate = knowledgeCandidate{Kind: kind, ID: int64(id), Version: version}
		}
		if !allowed[candidate] || seen[candidate] {
			return knowledgeTurnResult{}, errKnowledgeCitations
		}
		seen[candidate] = true
		result = append(result, candidate)
	}
	return knowledgeTurnResult{Answer: &answer, Sources: result}, nil
}
