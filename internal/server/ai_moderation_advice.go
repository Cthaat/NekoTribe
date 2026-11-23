package server

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type moderationModelConfig struct {
	System         string
	Queries        map[string]string
	ResponseSchema json.RawMessage
	options        map[string][]string
}

var moderationAdviceContract = func() moderationModelConfig {
	var config moderationModelConfig
	if json.Unmarshal(contracts.AIModerationAdvice, &config) != nil || len(config.Queries) != 4 || len(config.ResponseSchema) == 0 {
		panic("invalid moderation advice contract")
	}
	var schema struct {
		Properties map[string]struct{ Enum []string }
	}
	if json.Unmarshal(config.ResponseSchema, &schema) != nil ||
		len(schema.Properties["risk"].Enum) == 0 || len(schema.Properties["recommendation"].Enum) == 0 {
		panic("invalid moderation response schema")
	}
	config.options = map[string][]string{
		"risk":           schema.Properties["risk"].Enum,
		"recommendation": schema.Properties["recommendation"].Enum,
	}
	return config
}()
var errModerationAdviceUnavailable = errors.New("moderation advice unavailable")

type moderationAdviceRequest struct {
	Kind         string
	ID, Sequence int64
	Locale       string
	SkillID      *string
	Vision       bool
}
type moderationTargetReference struct {
	Kind    string `json:"target_type"`
	ID      int64  `json:"target_id"`
	PostID  int64  `json:"post_id"`
	GroupID *int64 `json:"group_id"`
	Digest  string `json:"digest"`
}
type moderationOpinion struct {
	Risk           string  `json:"risk"`
	Reason         string  `json:"reason"`
	Recommendation string  `json:"recommendation"`
	RuleIDs        []int64 `json:"rule_ids"`
}
type moderationAdviceRecord struct {
	Version         int                       `json:"version"`
	Target          moderationTargetReference `json:"target"`
	Locale          string                    `json:"locale"`
	TermsDigest     string                    `json:"terms_digest"`
	TermsGeneration int64                     `json:"terms_generation"`
	SkillGeneration int64                     `json:"skill_generation"`
	Advice          moderationOpinion         `json:"advice"`
	ImageSources    []visionImageReference    `json:"image_sources,omitempty"`
}
type moderationRule struct {
	ID      int64    `json:"id"`
	Version string   `json:"version"`
	Title   string   `json:"title"`
	Blocks  []string `json:"blocks"`
}
type moderationMaterial struct {
	Target    moderationTargetReference
	Content   string
	Authority termsAuthority
	Rules     []moderationRule
	Images    []storedVisionImage
}

func moderationInteger(value interface{}) (int64, bool) {
	n, ok := value.(float64)
	if !ok || n < 0 || n > 999999999999999 || n != float64(int64(n)) {
		return 0, false
	}
	return int64(n), true
}
func parseModerationAdviceRequest(raw []byte) (moderationAdviceRequest, error) {
	data, ok := ai.DecodeScalarJSON(raw, 8)
	body, object := data.(map[string]interface{})
	rawSkill, hasSkill := body["skill_id"]
	fieldCount := 4
	var skillID *string
	if hasSkill {
		skill, valid := rawSkill.(string)
		if !valid || skill != "moderation-advice" {
			return moderationAdviceRequest{}, errConversationInvalid
		}
		skillID = &skill
		fieldCount++
	}
	if !ok || !object || len(body) != fieldCount || hasTooManyJSONMembers(raw, fieldCount) {
		return moderationAdviceRequest{}, errConversationInvalid
	}
	kind, _ := body["target_type"].(string)
	locale, _ := body["locale"].(string)
	id, validID := moderationInteger(body["target_id"])
	sequence, validSequence := moderationInteger(body["expected_sequence"])
	if !validID || id == 0 || !validSequence || sequence >= 9999999999 ||
		moderationAdviceContract.Queries[kind] == "" || (locale != "en" && locale != "zh") {
		return moderationAdviceRequest{}, errConversationInvalid
	}
	return moderationAdviceRequest{Kind: kind, ID: id, Locale: locale, Sequence: sequence, SkillID: skillID}, nil
}
func moderationRuleAllowed(locale string, id int64) bool {
	return (locale == "zh" && id >= 1 && id <= 4) || (locale == "en" && id >= 5 && id <= 8)
}
func parseModerationOpinion(raw []byte, locale string) (moderationOpinion, error) {
	value, ok := ai.DecodeScalarJSON(raw, 8)
	body, object := value.(map[string]interface{})
	if !ok || !object || len(body) != 4 || len(raw) > 4096 || hasTooManyJSONMembers(raw, 4) {
		return moderationOpinion{}, errModerationAdviceUnavailable
	}
	result := moderationOpinion{}
	result.Risk, _ = body["risk"].(string)
	result.Reason, _ = body["reason"].(string)
	result.Recommendation, _ = body["recommendation"].(string)
	if !slices.Contains(moderationAdviceContract.options["risk"], result.Risk) ||
		!slices.Contains(moderationAdviceContract.options["recommendation"], result.Recommendation) {
		return moderationOpinion{}, errModerationAdviceUnavailable
	}
	refs, _ := body["rule_ids"].([]interface{})
	if len(refs) < 1 || len(refs) > 4 || strings.TrimFunc(result.Reason, jsTrimSpace) == "" ||
		len(result.Reason) > 1200 || (result.Risk == "none" && result.Recommendation == "consider_removal") {
		return moderationOpinion{}, errModerationAdviceUnavailable
	}
	seen := map[int64]bool{}
	for _, ref := range refs {
		id, valid := moderationInteger(ref)
		if !valid || !moderationRuleAllowed(locale, id) || seen[id] {
			return moderationOpinion{}, errModerationAdviceUnavailable
		}
		seen[id] = true
		result.RuleIDs = append(result.RuleIDs, id)
	}
	return result, nil
}

func moderationDigestHex(value string) bool {
	_, err := hex.DecodeString(value)
	return err == nil && len(value) == 64 && value == strings.ToLower(value)
}
func validModerationTarget(target moderationTargetReference) bool {
	return moderationAdviceContract.Queries[target.Kind] != "" &&
		validKnowledgeID(target.ID) && validKnowledgeID(target.PostID) &&
		(!(target.Kind == "post" || target.Kind == "group_post") || target.ID == target.PostID) &&
		(strings.HasPrefix(target.Kind, "group_") == (target.GroupID != nil)) &&
		(target.GroupID == nil || validKnowledgeID(*target.GroupID))
}
func decodeModerationAdvice(content string) *moderationAdviceRecord {
	var record moderationAdviceRecord
	if json.Unmarshal([]byte(content), &record) != nil || !validModerationTarget(record.Target) ||
		!moderationDigestHex(record.Target.Digest) || !moderationDigestHex(record.TermsDigest) ||
		!validKnowledgeID(record.TermsGeneration) || !validKnowledgeID(record.SkillGeneration) {
		return nil
	}
	switch record.Version {
	case 1:
		if len(record.ImageSources) != 0 {
			return nil
		}
	case 2:
		if !moderationHasImages(record.Target.Kind) || !validModerationImageReferences(record.ImageSources) {
			return nil
		}
	default:
		return nil
	}
	raw, err := json.Marshal(record.Advice)
	if err != nil {
		return nil
	}
	if _, err = parseModerationOpinion(raw, record.Locale); err != nil {
		return nil
	}
	return &record
}

func targetDigest(target moderationTargetReference, content string) string {
	group := ""
	if target.GroupID != nil {
		group = strconv.FormatInt(*target.GroupID, 10)
	}
	hash := sha256.New()
	for _, field := range []string{"moderation-target-v1", target.Kind, strconv.FormatInt(target.ID, 10),
		strconv.FormatInt(target.PostID, 10), group, content} {
		fmt.Fprintf(hash, "%d:%s", len(field), field)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func readModerationMaterial(ctx context.Context, tx *sql.Tx, actor int64, request moderationAdviceRequest, lockTerms bool) (*moderationMaterial, error) {
	query := moderationAdviceContract.Queries[request.Kind]
	if query == "" {
		return nil, errConversationInvalid
	}
	target := moderationTargetReference{Kind: request.Kind, ID: request.ID}
	var group, length sql.NullInt64
	var content sql.NullString
	err := tx.QueryRowContext(ctx, query, sql.Named("actor_id", actor), sql.Named("target_id", request.ID)).Scan(&target.PostID, &group, &content, &length)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, errSessionStore
	}
	if group.Valid {
		target.GroupID = &group.Int64
	}
	if !validModerationTarget(target) {
		return nil, errSessionStore
	}
	textPresent := length.Valid && length.Int64 >= 1 && content.Valid && strings.TrimFunc(content.String, jsTrimSpace) != ""
	if length.Int64 > 1000 || len(content.String) > 4000 || (!textPresent && (!request.Vision || !moderationHasImages(request.Kind))) {
		return nil, nil
	}
	if textPresent && !termsTextValid(content.String) {
		return nil, errSessionStore
	}
	target.Digest = targetDigest(target, content.String)
	raw := contracts.PublicTermsCatalog()
	authority, err := readPublicTermsAuthorityMode(ctx, tx, actor, raw, lockTerms)
	if err != nil {
		return nil, err
	}
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		return nil, errTermsAuthorityUnavailable
	}
	rules := make([]moderationRule, 0, 4)
	for _, row := range catalog {
		if row.Locale == request.Locale {
			rules = append(rules, moderationRule{row.ID, row.Version, row.Title, row.Blocks})
		}
	}
	return &moderationMaterial{Target: target, Content: content.String, Authority: authority, Rules: rules}, nil
}

type moderationDisplayTarget struct {
	Kind    string `json:"kind"`
	ID      int64  `json:"id"`
	PostID  int64  `json:"post_id"`
	GroupID *int64 `json:"group_id"`
}
type visibleModerationAdvice struct {
	moderationOpinion
	Target       moderationDisplayTarget `json:"target"`
	Rules        []publicTermsReference  `json:"rules"`
	AnalysisMode string                  `json:"analysis_mode"`
}

func currentModerationAdvice(ctx context.Context, tx *sql.Tx, actor int64, record *moderationAdviceRecord, lockTerms bool) (*visibleModerationAdvice, error) {
	material, err := readModerationMaterial(ctx, tx, actor, moderationAdviceRequest{
		Kind: record.Target.Kind, ID: record.Target.ID, Locale: record.Locale, Vision: record.Version == 2,
	}, lockTerms)
	if err != nil {
		return nil, err
	}
	if material == nil || material.Target.Digest != record.Target.Digest ||
		material.Authority.Digest != record.TermsDigest || material.Authority.Generation != record.TermsGeneration {
		return nil, errConversationConflict
	}
	result := &visibleModerationAdvice{moderationOpinion: record.Advice,
		Target: moderationDisplayTarget{record.Target.Kind, record.Target.ID, record.Target.PostID, record.Target.GroupID}, AnalysisMode: "text_only"}
	if record.Version == 2 {
		if err := recheckModerationVisionImages(ctx, tx, actor, record); err != nil {
			return nil, err
		}
		result.AnalysisMode = "text_and_images"
	}
	for _, rule := range material.Rules {
		for _, id := range record.Advice.RuleIDs {
			if id == rule.ID {
				result.Rules = append(result.Rules, publicTermsReference{Kind: "terms", ID: id, Version: rule.Version})
			}
		}
	}
	return result, nil
}

type moderationAdviceStore interface {
	loadModerationAdvice(context.Context, int64, string, moderationAdviceRequest, moderationPolicy) (*moderationMaterial, int64, error)
	verifyModerationVisionInputs(context.Context, int64, *moderationAdviceRecord) error
	appendAIAssistantMessage(context.Context, int64, string, assistantMessageInput, moderationPolicy) (conversationMessage, error)
}

func (s OracleSessions) loadModerationAdvice(ctx context.Context, actor int64, id string, request moderationAdviceRequest, policy moderationPolicy) (*moderationMaterial, int64, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer conn.Close()
	if verifyConversationSchema(ctx, conn) != nil {
		return nil, 0, errConversationSchema
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer tx.Rollback()
	record, err := readConversationRow(ctx, tx, actor, id, policy, false)
	if err != nil {
		return nil, 0, err
	}
	if record.Purpose != "moderation" {
		return nil, 0, errConversationInvalid
	}
	var sequence int64
	if tx.QueryRowContext(ctx, "SELECT NVL(MAX(sequence_no),0) FROM n_ai_messages WHERE conversation_id=:conversation_id", sql.Named("conversation_id", id)).Scan(&sequence) != nil {
		return nil, 0, errSessionStore
	}
	if sequence != request.Sequence {
		return nil, 0, errConversationConflict
	}
	selected, err := selectConfiguredConversationSkill(ctx, tx, actor, id, request.SkillID, policy)
	if err != nil {
		return nil, 0, err
	}
	material, err := readModerationMaterial(ctx, tx, actor, request, false)
	if err != nil {
		return nil, 0, err
	}
	if material != nil && request.Vision && moderationHasImages(request.Kind) {
		material.Images, err = readModerationVisionImages(ctx, tx, actor, material.Target)
		if err != nil {
			return nil, 0, err
		}
	}
	if tx.Rollback() != nil {
		return nil, 0, errSessionStore
	}
	return material, selected.Generation, nil
}
func generateModerationAdvice(ctx context.Context, store moderationAdviceStore, actor int64, id string, policy moderationPolicy, config RefreshConfig, request moderationAdviceRequest) (saved *conversationMessage, runErr error) {
	router, modelErr := config.modelRouter()
	var model ai.Selection
	if modelErr == nil {
		model, modelErr = router.Select("moderation", []string{"structured-output"})
	}
	request.Vision = modelErr == nil && moderationHasImages(request.Kind) && slices.Contains(model.Capabilities, "vision")
	material, generation, err := store.loadModerationAdvice(ctx, actor, id, request, policy)
	if err != nil {
		return nil, err
	}
	audit := newAIRunAudit("moderation_advice", generation)
	if request.SkillID != nil {
		audit.skillSelection = "explicit"
	}
	defer func() { audit.finish(ctx, saved, runErr) }()
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if material == nil {
		return nil, nil
	}
	audit.stage = "configuration"
	if modelErr != nil {
		return nil, errModerationAdviceUnavailable
	}
	audit.configRevision = model.ConfigurationRevision
	contract := moderationAdviceContract
	var images []ai.VisionImage
	var imageSources []visionImageReference
	system := contract.System
	if request.Vision {
		images, imageSources = moderationVisionInputs(ctx, config.LocalStorage, material.Images)
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if len(images) > 0 {
			system = strings.Replace(contract.System, "这条公开文本", "这条公开帖子提供的文本和附带图片", 1)
		}
	}
	if len(images) == 0 && strings.TrimFunc(material.Content, jsTrimSpace) == "" {
		return nil, nil
	}
	prompt, err := json.Marshal(map[string]interface{}{"target_type": request.Kind, "locale": request.Locale, "content": material.Content, "rules": material.Rules})
	budget := min(16384, model.ContextWindowTokens-model.MaxOutputTokens-512)
	if err != nil || int64(len(prompt)+len(system)+len(contract.ResponseSchema)+64) > budget {
		return nil, errModerationAdviceUnavailable
	}
	packet, err := json.Marshal(map[string]interface{}{
		"responseSchema": contract.ResponseSchema, "messages": []map[string]string{
			{"role": "system", "content": system}, {"role": "user", "content": string(prompt)},
		},
	})
	if err != nil {
		return nil, errModerationAdviceUnavailable
	}
	transport, err := ai.NewTransport(config.aiCredential)
	if err != nil {
		return nil, errModerationAdviceUnavailable
	}
	defer transport.CloseIdleConnections()
	review := &moderationAdviceRecord{Version: 1, Target: material.Target, Locale: request.Locale, TermsDigest: material.Authority.Digest,
		TermsGeneration: material.Authority.Generation, SkillGeneration: generation, ImageSources: imageSources}
	if len(imageSources) > 0 {
		review.Version = 2
		audit.stage = "evidence"
		if err := store.verifyModerationVisionInputs(ctx, actor, review); err != nil {
			return nil, err
		}
	}
	audit.stage = "quota"
	if err := requireAIModelQuota(ctx, config.AIModelQuotaLimiter, actor, 1); err != nil {
		return nil, err
	}
	audit.stage = "inference"
	inferenceCtx := ctx
	if len(images) > 0 {
		inferenceCtx = ai.WithStreamDeltas(ctx, nil)
	}
	result, err := transport.InferWithImages(inferenceCtx, model, packet, images)
	if err != nil || result.FinishReason != "stop" || len(result.ToolCalls) != 0 || ctx.Err() != nil {
		return nil, errModerationAdviceUnavailable
	}
	advice, err := parseModerationOpinion([]byte(result.Text), request.Locale)
	if err != nil {
		return nil, err
	}
	for _, id := range advice.RuleIDs {
		if !slices.ContainsFunc(material.Rules, func(rule moderationRule) bool { return rule.ID == id }) {
			return nil, errModerationAdviceUnavailable
		}
	}
	review.Advice = advice
	audit.stage = "persist"
	message, err := store.appendAIAssistantMessage(ctx, actor, id, assistantMessageInput{
		ModerationAdvice: review, ExpectedSequence: request.Sequence, ModelID: model.ProfileID, ModelVersion: model.ModelVersion,
		ConfigRevision: model.ConfigurationRevision, SkillGeneration: generation,
	}, policy)
	if err != nil {
		return nil, err
	}
	return &message, nil
}
