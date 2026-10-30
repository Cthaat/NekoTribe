package server

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

var errKnowledgeSearchBody = errors.New("invalid knowledge search body")

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

func parseKnowledgeSearchBody(raw []byte) (*string, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	if len(raw) > 4096 || !utf8.Valid(raw) || !validJSONSurrogates(raw) {
		return nil, errKnowledgeSearchBody
	}
	var value interface{}
	if json.Unmarshal(raw, &value) != nil {
		return nil, errKnowledgeSearchBody
	}
	body, ok := value.(map[string]interface{})
	if !ok {
		return nil, errKnowledgeSearchBody
	}
	if len(body) == 0 {
		return nil, nil
	}
	phrase, ok := body["search_phrase"].(string)
	if !ok || len(body) != 1 {
		return nil, errKnowledgeSearchBody
	}
	term := strings.TrimFunc(phrase, jsTrimSpace)
	if term == "" || len(term) > 256 || strings.IndexFunc(term, func(r rune) bool { return r <= 0x1f || r == 0x7f }) >= 0 {
		return nil, errKnowledgeSearchBody
	}
	return &term, nil
}
