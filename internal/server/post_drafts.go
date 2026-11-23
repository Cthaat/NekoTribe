package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type postDraftPolicy struct {
	SweepInterval int               `json:"sweep_interval_seconds"`
	SweepBatch    int               `json:"sweep_batch_size"`
	DefaultLimit  int               `json:"default_list_limit"`
	MaxLimit      int               `json:"max_list_limit"`
	MaxPayload    int               `json:"max_payload_bytes"`
	SQL           map[string]string `json:"sql"`
}

var postDrafts = func() postDraftPolicy {
	var policy postDraftPolicy
	if json.Unmarshal(contracts.PostDrafts, &policy) != nil || policy.SweepBatch < 1 || policy.SweepInterval < 1 ||
		policy.DefaultLimit < 1 || policy.MaxLimit < policy.DefaultLimit || policy.MaxPayload < 1 {
		panic("invalid post draft contract")
	}
	return policy
}()

var (
	errPostDraftInvalid     = errors.New("post draft input invalid")
	errPostDraftMissing     = errors.New("post draft not found")
	errPostDraftPublished   = errors.New("post draft already published")
	errPostDraftUnavailable = errors.New("post draft schema unavailable")
	errPostDraftSchedule    = errors.New("post draft schedule must be in the future")
	errPostDraftPollCutoff  = errors.New("post draft poll must close after its scheduled time")
)

type postDraftRecord struct {
	ID          int64           `json:"draft_id"`
	Payload     json.RawMessage `json:"payload"`
	Status      string          `json:"status"`
	ScheduledAt *string         `json:"scheduled_at"`
	PublishedID *int64          `json:"published_post_id"`
	LastError   *string         `json:"last_error"`
	UpdatedAt   string          `json:"updated_at"`
	owner       int64
	group       *int64
	input       postDraftPayload
}

type postDraftList struct {
	Items      []postDraftRecord `json:"items"`
	NextBefore *int64            `json:"next_before_id"`
}

type postDraftQuery struct {
	before, group *int64
	limit         int
}

type postDraftAction struct {
	kind string
	id   int64
	when time.Time
	body postDraftPayload
}

type postDraftPayload struct {
	json    json.RawMessage
	regular PostCreateInput
	group   groupPostMutation
}

func parsePostDraft(raw []byte) (postDraftPayload, error) {
	var body map[string]any
	if len(raw) > postDrafts.MaxPayload || json.Unmarshal(raw, &body) != nil || body == nil {
		return postDraftPayload{}, errPostDraftInvalid
	}
	content, ok := body["content"].(string)
	group, hasGroup := body["group_id"]
	if !ok || len(content) > 4000 || !hasGroup {
		return postDraftPayload{}, errPostDraftInvalid
	}
	out := postDraftPayload{regular: PostCreateInput{Content: content}}
	var poll *postPollCreation
	if value, exists := body["poll"]; exists {
		var err error
		poll, err = parsePostPollCreation(value)
		if err != nil {
			return postDraftPayload{}, errPostDraftInvalid
		}
		body["poll"] = map[string]any{
			"options": poll.options, "multiple": poll.multiple, "closes_at": poll.closesAt.Format(postUTCDateLayout),
		}
	}
	var markdown *string
	if value, exists := body["markdown"]; exists {
		var err error
		markdown, err = parsePostMarkdown(value)
		if err != nil {
			return postDraftPayload{}, err
		}
	}
	if group == nil {
		out.regular.Poll = poll
		out.regular.Markdown = markdown
		if err := parseRegularPostDraft(body, &out.regular); err != nil {
			return postDraftPayload{}, err
		}
	} else {
		groupID, valid := chatSendID(group)
		if !valid {
			return postDraftPayload{}, errPostDraftInvalid
		}
		out.group = groupPostMutation{action: "create", group: groupID, content: strings.TrimFunc(content, jsTrimSpace), poll: poll, markdown: markdown}
		if err := parseGroupPostDraft(body, &out.group); err != nil {
			return postDraftPayload{}, err
		}
	}
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(body); err != nil || encoded.Len()-1 > postDrafts.MaxPayload {
		return postDraftPayload{}, errPostDraftInvalid
	}
	out.json = encoded.Bytes()[:encoded.Len()-1]
	return out, nil
}

func parseRegularPostDraft(body map[string]any, draft *PostCreateInput) error {
	for field, value := range body {
		switch field {
		case "group_id", "content", "poll", "markdown":
		case "visibility":
			visibility, ok := value.(string)
			if !ok || !slices.Contains([]string{"public", "followers", "mentioned", "private"}, visibility) {
				return errPostDraftInvalid
			}
			draft.Visibility = visibility
		case "media_ids", "mention_user_ids":
			limit, destination := 4, &draft.MediaIDs
			if field == "mention_user_ids" {
				limit, destination = 50, &draft.Mentions
			}
			items, ok := value.([]any)
			if !ok || len(items) > limit {
				return errPostDraftInvalid
			}
			for _, item := range items {
				id, ok := chatSendID(item)
				if !ok {
					return errPostDraftInvalid
				}
				*destination = append(*destination, float64(id))
			}
		case "tag_names":
			tags, ok := postDraftStrings(value, 20, 100)
			if !ok {
				return errPostDraftInvalid
			}
			draft.Tags = tags
		case "location":
			location, ok := value.(string)
			if !ok || len(location) > 100 {
				return errPostDraftInvalid
			}
			draft.Location = location
		default:
			return errPostDraftInvalid
		}
	}
	return nil
}

func parseGroupPostDraft(body map[string]any, draft *groupPostMutation) error {
	for field, value := range body {
		switch field {
		case "group_id", "content", "poll", "markdown":
		case "is_announcement":
			announcement, ok := value.(bool)
			if !ok {
				return errPostDraftInvalid
			}
			draft.announcement = announcement
		case "media_urls":
			urls, ok := postDraftStrings(value, 4, 2000)
			if !ok || len(strings.Join(urls, ",")) > 2000 {
				return errPostDraftInvalid
			}
			stored := make([]string, 0, len(urls))
			for _, raw := range urls {
				url := strings.TrimFunc(raw, jsTrimSpace)
				if strings.Contains(url, ",") {
					return errPostDraftInvalid
				}
				if url != "" {
					stored = append(stored, url)
				}
			}
			draft.media = strings.Join(stored, ",")
		default:
			return errPostDraftInvalid
		}
	}
	return nil
}

func postDraftStrings(value any, maxItems, maxBytes int) ([]string, bool) {
	items, ok := value.([]any)
	if !ok || len(items) > maxItems {
		return nil, false
	}
	values := make([]string, 0, len(items))
	for _, item := range items {
		value, ok := item.(string)
		if !ok || len(value) > maxBytes {
			return nil, false
		}
		values = append(values, value)
	}
	return values, true
}
