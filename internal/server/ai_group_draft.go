package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type groupDraftDefinition struct {
	System                  string
	ActivityPlanInstruction string
	LookbackDays            map[string]int
	RequiredTool            string
	Tools                   []groupDraftTool
}

type groupDraftTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

var groupDraftContract = func() groupDraftDefinition {
	var config groupDraftDefinition
	if json.Unmarshal(contracts.AIGroupDraft, &config) != nil || config.System == "" ||
		config.ActivityPlanInstruction == "" || len(config.Tools) != 2 {
		panic("invalid group draft contract")
	}
	return config
}()

type groupDraftRequest struct {
	Kind             string `json:"kind"`
	ExpectedSequence int64  `json:"expected_sequence"`
	SkillID          *string
	searchTerm       *string
}

func parseGroupDraftRequest(raw []byte) (groupDraftRequest, error) {
	var body map[string]interface{}
	if !utf8.Valid(raw) || !validJSONSurrogates(raw) || json.Unmarshal(raw, &body) != nil || hasTooManyJSONMembers(raw, len(body)) {
		return groupDraftRequest{}, errConversationInvalid
	}
	var skillID *string
	var searchTerm *string
	expectedFields := 2
	if value, present := body["skill_id"]; present {
		skill, _ := value.(string)
		if skill != "group-brief" {
			return groupDraftRequest{}, errConversationInvalid
		}
		skillID = &skill
		expectedFields++
	}
	if value, present := body["search_term"]; present {
		term, ok := value.(string)
		if !ok || !validGroupDraftSearchTerm(term) {
			return groupDraftRequest{}, errConversationInvalid
		}
		searchTerm = &term
		expectedFields++
	}
	kind, _ := body["kind"].(string)
	sequence, ok := body["expected_sequence"].(float64)
	if len(body) != expectedFields || groupDraftContract.LookbackDays[kind] == 0 || !ok ||
		sequence < 0 || sequence >= 9999999999 || sequence != float64(int64(sequence)) {
		return groupDraftRequest{}, errConversationInvalid
	}
	return groupDraftRequest{Kind: kind, ExpectedSequence: int64(sequence), SkillID: skillID, searchTerm: searchTerm}, nil
}

type groupDraftRecord struct {
	Version               int      `json:"version"`
	Kind                  string   `json:"kind"`
	WindowEnd             string   `json:"window_end"`
	SourceDigest          string   `json:"source_digest"`
	ExampleCount          int      `json:"example_count"`
	SkillGeneration       int64    `json:"skill_generation"`
	Draft                 string   `json:"draft"`
	ToolsUsed             []string `json:"tools_used,omitempty"`
	SearchTerm            *string  `json:"search_term,omitempty"`
	MatchExcerpt          bool     `json:"match_excerpt,omitempty"`
	SentimentSourceDigest string   `json:"sentiment_source_digest,omitempty"`
}

type groupDraftSource struct {
	Kind     string `json:"kind"`
	SourceID int64  `json:"source_id"`
	PostID   int64  `json:"post_id"`
}

func groupEvidenceDigest(data groupEvidence) string {
	hash := sha256.New()
	add := func(value interface{}) {
		text := fmt.Sprint(value)
		fmt.Fprintf(hash, "%d:%s", len(text), text)
	}
	for _, field := range []interface{}{"group-evidence-v1", data.WindowStart, data.WindowEnd, data.PostsCount, data.CommentsCount} {
		add(field)
	}
	for _, row := range data.Examples {
		for _, field := range []interface{}{row.Kind, row.SourceID, row.PostID, row.Excerpt} {
			add(field)
		}
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func decodeGroupDraft(content string) *groupDraftRecord {
	var draft groupDraftRecord
	if json.Unmarshal([]byte(content), &draft) != nil || draft.Version != 1 ||
		groupDraftContract.LookbackDays[draft.Kind] == 0 || !groupEvidenceTimestamp.MatchString(draft.WindowEnd) ||
		len(draft.SourceDigest) != 64 || draft.ExampleCount < 1 || draft.ExampleCount > 8 || draft.SkillGeneration < 1 ||
		draft.Draft == "" || len(draft.Draft) > 8192 || !utf8.ValidString(draft.Draft) ||
		(draft.ToolsUsed != nil && !validGroupDraftTools(draft.ToolsUsed)) ||
		(draft.SearchTerm != nil && !validGroupDraftSearchTerm(*draft.SearchTerm)) ||
		(draft.MatchExcerpt && draft.SearchTerm == nil) {
		return nil
	}
	if _, err := hex.DecodeString(draft.SourceDigest); err != nil || draft.SourceDigest != strings.ToLower(draft.SourceDigest) {
		return nil
	}
	if slices.Contains(draft.ToolsUsed, sentimentContract.Tool.Name) {
		if !moderationDigestHex(draft.SentimentSourceDigest) {
			return nil
		}
	} else if draft.SentimentSourceDigest != "" {
		return nil
	}
	return &draft
}

func validGroupDraftSearchTerm(term string) bool {
	return term != "" && len(term) <= 256 && utf8.ValidString(term) &&
		strings.TrimFunc(term, jsTrimSpace) == term &&
		strings.IndexFunc(term, func(ch rune) bool { return ch < 32 || ch == 127 }) < 0
}

func validGroupDraftTools(names []string) bool {
	if len(names) > len(groupDraftContract.Tools)+1 || !slices.Contains(names, groupDraftContract.RequiredTool) {
		return false
	}
	for index, name := range names {
		if slices.Contains(names[:index], name) ||
			(name != sentimentContract.Tool.Name && !slices.ContainsFunc(groupDraftContract.Tools, func(tool groupDraftTool) bool { return tool.Name == name })) {
			return false
		}
	}
	return true
}

func recheckGroupDraft(ctx context.Context, tx *sql.Tx, actor, groupID int64, draft *groupDraftRecord) (groupEvidence, error) {
	if draft.ExampleCount < 1 || draft.ExampleCount > 8 {
		return groupEvidence{}, errConversationInvalid
	}
	evidence, err := readGroupEvidence(ctx, tx, actor, groupID, groupEvidenceQuery{
		LookbackDays: groupDraftContract.LookbackDays[draft.Kind], WindowEnd: &draft.WindowEnd, SearchTerm: draft.SearchTerm,
		MatchExcerpt: draft.MatchExcerpt,
	})
	if err != nil {
		return groupEvidence{}, err
	}
	base := evidence
	base.Examples = base.Examples[:min(len(base.Examples), draft.ExampleCount)]
	if groupEvidenceDigest(base) != draft.SourceDigest {
		return groupEvidence{}, errConversationConflict
	}
	if draft.SentimentSourceDigest != "" {
		previous, err := readGroupEvidence(ctx, tx, actor, groupID, groupSentimentEvidenceQuery(draft.Kind, draft.SearchTerm, draft.MatchExcerpt, evidence))
		if err != nil {
			return groupEvidence{}, err
		}
		if groupSentimentSourceDigest(evidence, previous) != draft.SentimentSourceDigest {
			return groupEvidence{}, errConversationConflict
		}
	}
	return base, nil
}

type groupDraftStore interface {
	loadGroupDraft(context.Context, int64, string, groupDraftRequest, moderationPolicy) (groupEvidence, int64, error)
	appendAIAssistantMessage(context.Context, int64, string, assistantMessageInput, moderationPolicy) (conversationMessage, error)
}

func (s OracleSessions) loadGroupDraft(ctx context.Context, actor int64, id string, request groupDraftRequest, policy moderationPolicy) (groupEvidence, int64, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return groupEvidence{}, 0, errSessionStore
	}
	defer conn.Close()
	if verifyConversationSchema(ctx, conn) != nil {
		return groupEvidence{}, 0, errConversationSchema
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return groupEvidence{}, 0, errSessionStore
	}
	defer tx.Rollback()
	record, err := readConversationRow(ctx, tx, actor, id, policy, false)
	if err != nil {
		return groupEvidence{}, 0, err
	}
	if record.Purpose != "group" || record.GroupID == nil {
		return groupEvidence{}, 0, errConversationInvalid
	}
	evidence, err := readGroupEvidence(ctx, tx, actor, *record.GroupID, groupEvidenceQuery{
		LookbackDays: groupDraftContract.LookbackDays[request.Kind], SearchTerm: request.searchTerm,
		MatchExcerpt: request.searchTerm != nil,
	})
	if err != nil {
		return groupEvidence{}, 0, err
	}
	var sequence int64
	if tx.QueryRowContext(ctx, "SELECT NVL(MAX(sequence_no),0) AS last_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id", sql.Named("conversation_id", id)).Scan(&sequence) != nil {
		return groupEvidence{}, 0, errSessionStore
	}
	if sequence != request.ExpectedSequence {
		return groupEvidence{}, 0, errConversationConflict
	}
	selected, err := selectConfiguredConversationSkill(ctx, tx, actor, id, request.SkillID, policy)
	if err != nil {
		return groupEvidence{}, 0, err
	}
	for _, tool := range groupDraftContract.Tools {
		if !slices.Contains(selected.Skill.Tools, tool.Name) {
			return groupEvidence{}, 0, errSkillUnavailable
		}
	}
	if tx.Rollback() != nil {
		return groupEvidence{}, 0, errSessionStore
	}
	return evidence, selected.Generation, nil
}

var errGroupDraftUnavailable = errors.New("group draft unavailable")

func generateGroupDraft(ctx context.Context, store groupDraftStore, actor int64, id string, policy moderationPolicy, config RefreshConfig, request groupDraftRequest) (saved *conversationMessage, runErr error) {
	evidence, generation, err := store.loadGroupDraft(ctx, actor, id, request, policy)
	if err != nil {
		return nil, err
	}
	audit := newAIRunAudit("group_draft", generation)
	if request.SkillID != nil {
		audit.skillSelection = "explicit"
	}
	defer func() { audit.finish(ctx, saved, runErr) }()
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if len(evidence.Examples) == 0 {
		return nil, nil
	}
	audit.stage = "configuration"
	router, err := config.modelRouter()
	if err != nil {
		return nil, errGroupDraftUnavailable
	}
	selection, err := router.Select("agent", []string{"tools"})
	if err != nil {
		return nil, errGroupDraftUnavailable
	}
	audit.configRevision = selection.ConfigurationRevision
	budget := min(16384, selection.ContextWindowTokens-selection.MaxOutputTokens-512)
	task := map[string]string{"kind": request.Kind}
	if request.searchTerm != nil {
		task["search_term"] = *request.searchTerm
	}
	input, err := encodeGroupDraftInput(task)
	if err != nil {
		return nil, errGroupDraftUnavailable
	}
	system := groupDraftContract.System
	if request.Kind == "activity_plan" {
		system += "\n" + groupDraftContract.ActivityPlanInstruction
	}
	messages := []map[string]any{
		{"role": "system", "content": system},
		{"role": "user", "content": string(input)},
	}
	packet, err := encodeGroupDraftInput(map[string]any{"messages": messages, "tools": groupDraftContract.Tools})
	if err != nil || int64(len(packet)+64) > budget {
		return nil, errGroupDraftUnavailable
	}
	sentimentOffered := false
	if config.sentiment != nil {
		tools := append(slices.Clone(groupDraftContract.Tools), sentimentContract.Tool)
		messages[0]["content"] = system + "\n如需概括讨论情绪，可请求一次 community_sentiment_summary，仅传空对象。情绪结果是可见样本趋势，不代表全部成员。工具不可用时不推测情绪。"
		withSentiment, err := encodeGroupDraftInput(map[string]any{"messages": messages, "tools": tools})
		if err == nil && int64(len(withSentiment)+64) <= budget {
			packet, sentimentOffered = withSentiment, true
		} else {
			messages[0]["content"] = system
		}
	}
	transport, err := ai.NewTransport(config.aiCredential)
	if err != nil {
		return nil, errGroupDraftUnavailable
	}
	defer transport.CloseIdleConnections()
	audit.stage = "quota"
	if err := requireAIModelQuota(ctx, config.AIModelQuotaLimiter, actor, 2); err != nil {
		return nil, err
	}
	audit.stage = "proposal"
	proposal, err := transport.Infer(ctx, selection, packet)
	if err != nil || proposal.FinishReason != "tool-calls" || ctx.Err() != nil {
		return nil, errGroupDraftUnavailable
	}
	names := make([]string, 0, len(proposal.ToolCalls))
	for _, call := range proposal.ToolCalls {
		if len(call.Arguments) != 0 {
			term, ok := call.Arguments["search_term"].(string)
			if call.Name != groupDraftContract.RequiredTool || len(call.Arguments) != 1 ||
				!ok || !validGroupDraftSearchTerm(term) || (request.searchTerm != nil && term != *request.searchTerm) {
				return nil, errGroupDraftUnavailable
			}
			request.searchTerm = &term
		}
		names = append(names, call.Name)
	}
	sentimentRequested := slices.Contains(names, sentimentContract.Tool.Name)
	if !validGroupDraftTools(names) || (sentimentRequested && !sentimentOffered) {
		return nil, errGroupDraftUnavailable
	}
	audit.stage = "evidence"
	evidence, currentGeneration, err := store.loadGroupDraft(ctx, actor, id, request, policy)
	if err != nil {
		return nil, err
	}
	if ctx.Err() != nil {
		return nil, errGroupDraftUnavailable
	}
	if generation != currentGeneration {
		return nil, errConversationConflict
	}
	if len(evidence.Examples) == 0 {
		return nil, nil
	}
	var sentiment *groupSentimentReport
	var sentimentDigest string
	if sentimentRequested {
		sentiment, sentimentDigest = groupSentiment(ctx, store, config.sentiment, actor, id, policy, request, evidence)
		if sentiment == nil {
			names = slices.DeleteFunc(names, func(name string) bool { return name == sentimentContract.Tool.Name })
		}
	}
	messages = append(messages, map[string]any{"role": "assistant", "content": "", "toolCalls": proposal.ToolCalls})
	fullEvidence := evidence
	for {
		packet, err = groupDraftFollowup(messages, proposal.ToolCalls, evidence, sentiment)
		if err != nil {
			return nil, errGroupDraftUnavailable
		}
		if int64(len(packet)+64) <= budget {
			break
		}
		if len(evidence.Examples) > 1 {
			evidence.Examples = evidence.Examples[:len(evidence.Examples)-1]
			continue
		}
		if !sentimentRequested {
			return nil, errGroupDraftUnavailable
		}
		// Preserve the existing draft when only the optional tool history exceeds the budget.
		proposal.ToolCalls = slices.DeleteFunc(proposal.ToolCalls, func(call ai.ToolProposal) bool { return call.Name == sentimentContract.Tool.Name })
		messages[len(messages)-1]["toolCalls"] = proposal.ToolCalls
		messages[0]["content"] = system
		names = slices.DeleteFunc(names, func(name string) bool { return name == sentimentContract.Tool.Name })
		sentimentRequested, sentiment, sentimentDigest = false, nil, ""
		evidence = fullEvidence
	}
	audit.toolCount = len(names)
	audit.stage = "inference"
	inferenceCtx := ctx
	if sentiment != nil {
		inferenceCtx = ai.WithStreamDeltas(ctx, nil)
	}
	result, err := transport.Infer(inferenceCtx, selection, packet)
	if err != nil || result.FinishReason != "stop" || len(result.ToolCalls) != 0 ||
		strings.TrimFunc(result.Text, jsTrimSpace) == "" || len(result.Text) > 8192 || ctx.Err() != nil {
		return nil, errGroupDraftUnavailable
	}
	draft := &groupDraftRecord{Version: 1, Kind: request.Kind, WindowEnd: evidence.WindowEnd,
		SourceDigest: groupEvidenceDigest(evidence), ExampleCount: len(evidence.Examples), SkillGeneration: generation,
		Draft: result.Text, ToolsUsed: names, SearchTerm: request.searchTerm, MatchExcerpt: request.searchTerm != nil,
		SentimentSourceDigest: sentimentDigest}
	audit.stage = "persist"
	message, err := store.appendAIAssistantMessage(ctx, actor, id, assistantMessageInput{
		ExpectedSequence: request.ExpectedSequence, ModelID: selection.ProfileID, ModelVersion: selection.ModelVersion,
		ConfigRevision: selection.ConfigurationRevision, SkillGeneration: generation, GroupDraft: draft,
	}, policy)
	if err != nil {
		return nil, err
	}
	return &message, nil
}

func groupDraftFollowup(messages []map[string]any, calls []ai.ToolProposal, evidence groupEvidence, sentiment *groupSentimentReport) ([]byte, error) {
	followup := append([]map[string]any(nil), messages...)
	for _, call := range calls {
		var output any
		if call.Name == sentimentContract.Tool.Name {
			if sentiment == nil {
				output = map[string]string{"status": "unavailable"}
			} else {
				output = sentiment
			}
		} else {
			data := map[string]any{"window_start": evidence.WindowStart, "window_end": evidence.WindowEnd}
			if call.Name == groupDraftContract.RequiredTool {
				data["examples"] = evidence.Examples
			} else {
				data["posts_count"] = evidence.PostsCount
				data["comments_count"] = evidence.CommentsCount
			}
			output = data
		}
		content, err := encodeGroupDraftInput(output)
		if err != nil {
			return nil, err
		}
		followup = append(followup, map[string]any{"role": "tool", "toolCallId": call.ID, "content": string(content)})
	}
	return encodeGroupDraftInput(map[string]any{"messages": followup})
}

func encodeGroupDraftInput(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'}), nil
}
