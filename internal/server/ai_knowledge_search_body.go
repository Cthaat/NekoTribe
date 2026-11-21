package server

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

var errKnowledgeSearchBody = errors.New("invalid knowledge search body")

// Count top-level JSON members after syntax validation, without interpreting quoted punctuation.
func hasTooManyJSONMembers(raw []byte, max int) bool {
	depth, fields := 0, 0
	inString, escaped := false, false
	for _, c := range raw {
		if inString {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				inString = false
			}
		} else if c == '"' {
			inString = true
		} else if c == '{' || c == '[' {
			depth++
		} else if c == '}' || c == ']' {
			depth--
		} else if c == ':' && depth == 1 {
			fields++
			if fields > max {
				return true
			}
		}
	}
	return false
}

// json.Unmarshal replaces unpaired UTF-16 escapes; reject them before decoding.
func validJSONSurrogates(raw []byte) bool {
	inString := false
	for i := 0; i < len(raw); i++ {
		if !inString {
			if raw[i] == '"' {
				inString = true
			}
			continue
		}
		if raw[i] == '"' {
			inString = false
			continue
		}
		if raw[i] != '\\' {
			continue
		}
		i++
		if i >= len(raw) {
			return false
		}
		if raw[i] != 'u' {
			continue
		}
		if i+4 >= len(raw) {
			return false
		}
		n, err := strconv.ParseUint(string(raw[i+1:i+5]), 16, 16)
		if err != nil {
			return false
		}
		i += 4
		if n >= 0xdc00 && n <= 0xdfff {
			return false
		}
		if n >= 0xd800 && n <= 0xdbff {
			if i+6 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
				return false
			}
			low, err := strconv.ParseUint(string(raw[i+3:i+7]), 16, 16)
			if err != nil || low < 0xdc00 || low > 0xdfff {
				return false
			}
			i += 6
		}
	}
	return true
}

type knowledgeSearchBody struct {
	Phrase           *string
	SkillID          *string
	ExpectedSequence int64
}

func expectedAISequence(value any) (int64, bool) {
	number, ok := value.(float64)
	if !ok || number < 1 || number > 9999999999 || float64(int64(number)) != number {
		return 0, false
	}
	return int64(number), true
}

func parseKnowledgeSearchBody(raw []byte) (knowledgeSearchBody, error) {
	var input knowledgeSearchBody
	if len(raw) == 0 {
		return input, nil
	}
	if len(raw) > 4096 || !utf8.Valid(raw) || !validJSONSurrogates(raw) {
		return input, errKnowledgeSearchBody
	}
	var value interface{}
	if json.Unmarshal(raw, &value) != nil {
		return input, errKnowledgeSearchBody
	}
	body, ok := value.(map[string]interface{})
	if !ok || len(body) > 3 || hasTooManyJSONMembers(raw, len(body)) {
		return input, errKnowledgeSearchBody
	}
	for key, value := range body {
		if key == "expected_sequence" {
			sequence, valid := expectedAISequence(value)
			if !valid {
				return knowledgeSearchBody{}, errKnowledgeSearchBody
			}
			input.ExpectedSequence = sequence
			continue
		}
		text, ok := value.(string)
		if !ok {
			return knowledgeSearchBody{}, errKnowledgeSearchBody
		}
		switch key {
		case "skill_id":
			if text != "knowledge-answer" {
				return knowledgeSearchBody{}, errKnowledgeSearchBody
			}
			input.SkillID = &text
		case "search_phrase":
			term := strings.TrimFunc(text, jsTrimSpace)
			if term == "" || len(term) > 256 || strings.IndexFunc(term, func(r rune) bool { return r <= 0x1f || r == 0x7f }) >= 0 {
				return knowledgeSearchBody{}, errKnowledgeSearchBody
			}
			input.Phrase = &term
		default:
			return knowledgeSearchBody{}, errKnowledgeSearchBody
		}
	}
	return input, nil
}
