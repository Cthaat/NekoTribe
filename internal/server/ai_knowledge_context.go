package server

import "unicode/utf8"

type knowledgeModelMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}
type knowledgeContext struct {
	Question string
	History  []knowledgeModelMessage
	Sources  []knowledgeCandidate
	Snapshot []conversationHistoryMessage
}

// jsJSONStringSize counts JSON.stringify UTF-8 bytes without Go's HTML or U+2028 escaping.
func jsJSONStringSize(value string) int {
	size := 2
	for _, r := range value {
		switch {
		case r == '"' || r == '\\' || r == '\b' || r == '\f' || r == '\n' || r == '\r' || r == '\t':
			size += 2
		case r < 0x20:
			size += 6
		default:
			size += utf8.RuneLen(r)
		}
	}
	return size
}

// selectKnowledgeContext retains a recent contiguous suffix and copies the exact inputs to be guarded.
func selectKnowledgeContext(messages []conversationHistoryMessage, maxBytes, maxSources int) (knowledgeContext, error) {
	if len(messages) == 0 || len(messages) > 50 || maxBytes < 0 || maxSources < 0 || maxSources > 20 {
		return knowledgeContext{}, errKnowledgeConversationContext
	}
	var previous int64
	for _, message := range messages {
		if message.SequenceNo <= previous || message.SequenceNo > 9999999999 || (message.Role != "user" && message.Role != "assistant") || message.Content == "" || !utf8.ValidString(message.Content) {
			return knowledgeContext{}, errKnowledgeConversationContext
		}
		previous = message.SequenceNo
		if message.Role == "assistant" {
			if len(message.Citations) == 0 || len(message.Citations) > 20 {
				return knowledgeContext{}, errKnowledgeConversationContext
			}
			refs := make([]knowledgeCandidate, 0, len(message.Citations))
			for _, c := range message.Citations {
				if (c.Kind == "terms" && c.PostID != 0) || (c.Kind != "terms" && (!validKnowledgeID(c.PostID) || (c.Kind == "post" && c.ID != c.PostID))) {
					return knowledgeContext{}, errKnowledgeConversationContext
				}
				refs = append(refs, knowledgeCandidate{Kind: c.Kind, ID: c.ID, Version: c.Version})
			}
			if validateKnowledgeCandidates(1, refs) != nil {
				return knowledgeContext{}, errKnowledgeConversationContext
			}
		} else if message.Citations != nil {
			return knowledgeContext{}, errKnowledgeConversationContext
		}
	}
	last := messages[len(messages)-1]
	if last.Role != "user" {
		return knowledgeContext{}, errKnowledgeConversationContext
	}
	result := knowledgeContext{Question: last.Content, History: []knowledgeModelMessage{}, Sources: []knowledgeCandidate{}}
	size := len(`{"question":`) + jsJSONStringSize(last.Content) + len(`,"history":[]}`)
	if size > maxBytes {
		return knowledgeContext{}, errKnowledgeContextTooLarge
	}
	versions := map[string]string{}
	first := len(messages) - 1
	for i := len(messages) - 2; i >= 0; i-- {
		message := messages[i]
		itemSize := len(`{"role":`) + jsJSONStringSize(message.Role) + len(`,"content":`) + jsJSONStringSize(message.Content) + 1
		if len(result.History) > 0 {
			itemSize++
		}
		if size+itemSize > maxBytes {
			break
		}
		newSources := []knowledgeCandidate{}
		for _, c := range message.Citations {
			key := knowledgeKey(c.Kind, c.ID)
			if version, ok := versions[key]; ok {
				if version != c.Version {
					return knowledgeContext{}, errKnowledgeConversationContext
				}
				continue
			}
			newSources = append(newSources, knowledgeCandidate{Kind: c.Kind, ID: c.ID, Version: c.Version})
		}
		if len(result.Sources)+len(newSources) > maxSources {
			break
		}
		for _, source := range newSources {
			versions[knowledgeKey(source.Kind, source.ID)] = source.Version
			result.Sources = append(result.Sources, source)
		}
		result.History = append([]knowledgeModelMessage{{Role: message.Role, Content: message.Content}}, result.History...)
		first = i
		size += itemSize
	}
	result.Snapshot = append([]conversationHistoryMessage(nil), messages[first:]...)
	for i := range result.Snapshot {
		if result.Snapshot[i].Citations != nil {
			result.Snapshot[i].Citations = append([]knowledgeCitation(nil), result.Snapshot[i].Citations...)
		}
	}
	return result, nil
}
