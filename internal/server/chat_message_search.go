package server

import (
	"database/sql"
	"encoding/json"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type chatMessageSearchDefinition struct {
	MaxKeywordBytes int `json:"max_keyword_bytes"`
	SQL             map[string]string
}

var chatMessageSearchContract = func() chatMessageSearchDefinition {
	var contract chatMessageSearchDefinition
	if json.Unmarshal(contracts.ChatMessageSearch, &contract) != nil || contract.MaxKeywordBytes <= 0 {
		panic("invalid chat message search contract")
	}
	for _, key := range []string{"keyword", "channel_sender", "direct_sender", "start", "end"} {
		if contract.SQL[key] == "" {
			panic("incomplete chat message search contract")
		}
	}
	return contract
}()

const chatMessageSearchWindowSQL = `
) WHERE rn BETWEEN :start_row AND :end_row
ORDER BY created_at ASC,message_id ASC`

var chatSearchTimePattern = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)

type chatMessageSearch struct {
	keyword string
	sender  int64
	start   string
	end     string
}

func (search chatMessageSearch) active() bool {
	return search != (chatMessageSearch{})
}

func parseChatMessageSearch(query string) (chatMessageSearch, bool) {
	var filter chatMessageSearch
	seen := make(map[string]bool, 4)
	for _, parameter := range strings.Split(query, "&") {
		rawKey, rawValue, _ := strings.Cut(parameter, "=")
		key, _ := url.QueryUnescape(rawKey)
		if key != "q" && key != "sender_id" && key != "start_at" && key != "end_at" {
			continue
		}
		value, err := url.QueryUnescape(rawValue)
		if err != nil || !utf8.ValidString(value) || seen[key] {
			return chatMessageSearch{}, false
		}
		seen[key] = true
		switch key {
		case "q":
			filter.keyword = strings.TrimFunc(value, jsTrimSpace)
			if len(filter.keyword) > chatMessageSearchContract.MaxKeywordBytes {
				return chatMessageSearch{}, false
			}
		case "sender_id":
			sender, err := strconv.ParseInt(value, 10, 64)
			if err != nil || !publicID.MatchString(value) || sender > maxSocketID {
				return chatMessageSearch{}, false
			}
			filter.sender = sender
		case "start_at":
			filter.start = normalizeChatSearchTime(value)
			if filter.start == "" {
				return chatMessageSearch{}, false
			}
		case "end_at":
			filter.end = normalizeChatSearchTime(value)
			if filter.end == "" {
				return chatMessageSearch{}, false
			}
		}
	}
	if filter.start != "" && filter.end != "" && filter.start >= filter.end {
		return chatMessageSearch{}, false
	}
	return filter, true
}

func normalizeChatSearchTime(value string) string {
	if !chatSearchTimePattern.MatchString(value) || strings.HasPrefix(value, "0000") {
		return ""
	}
	instant, err := time.Parse(time.RFC3339Nano, value)
	if err != nil || instant.UTC().Year() < 1 || instant.UTC().Year() > 9999 {
		return ""
	}
	return oracleTimestampValue(instant)
}

func (search chatMessageSearch) predicates(alias, senderKey string) (string, []any) {
	var clauses strings.Builder
	var binds []any
	add := func(key, name string, value any) {
		clauses.WriteByte('\n')
		clauses.WriteString(strings.ReplaceAll(chatMessageSearchContract.SQL[key], "{message}", alias))
		binds = append(binds, sql.Named(name, value))
	}
	if search.keyword != "" {
		add("keyword", "search_keyword", search.keyword)
	}
	if search.sender != 0 {
		add(senderKey, "search_sender", search.sender)
	}
	if search.start != "" {
		add("start", "search_start", search.start)
	}
	if search.end != "" {
		add("end", "search_end", search.end)
	}
	return clauses.String(), binds
}
