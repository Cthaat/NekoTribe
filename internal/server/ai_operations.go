package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var aiOpsContract = func() struct {
	Roles                                               []string
	HealthTimeoutMilliseconds, IndexTimeoutMilliseconds int
	IndexStatusPath, FeedbackSQL                        string
} {
	var spec struct {
		Roles                                               []string
		HealthTimeoutMilliseconds, IndexTimeoutMilliseconds int
		IndexStatusPath, FeedbackSQL                        string
	}
	if json.Unmarshal(contracts.AIOperationsContract, &spec) != nil {
		panic("invalid AI operations contract")
	}
	return spec
}()

type aiOpsFeedback struct {
	ModelID        *string  `json:"model_id"`
	ModelVersion   *string  `json:"model_version"`
	ConfigRevision *int64   `json:"config_revision"`
	Helpful        int64    `json:"helpful"`
	Incorrect      int64    `json:"incorrect"`
	Insufficient   int64    `json:"insufficient"`
	Accuracy       *float64 `json:"accuracy"`
}

type aiOpsSkill struct {
	ID      string `json:"id"`
	Purpose string `json:"purpose"`
	Version int    `json:"version"`
	Enabled bool   `json:"enabled"`
}

type aiOpsSkills struct {
	Generation int64        `json:"generation"`
	Items      []aiOpsSkill `json:"items"`
}

type aiOpsStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ReadAIOps(context.Context, int64) ([]aiOpsFeedback, *aiOpsSkills, error)
}

func (s OracleSessions) ReadAIOps(ctx context.Context, actor int64) ([]aiOpsFeedback, *aiOpsSkills, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer conn.Close()
	rows, err := conn.QueryContext(ctx, aiOpsContract.FeedbackSQL)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	feedback := []aiOpsFeedback{}
	for rows.Next() {
		var row aiOpsFeedback
		if err := rows.Scan(&row.ModelID, &row.ModelVersion, &row.ConfigRevision,
			&row.Helpful, &row.Incorrect, &row.Insufficient); err != nil {
			return nil, nil, err
		}
		if answered := row.Helpful + row.Incorrect; answered > 0 {
			accuracy := float64(row.Helpful) / float64(answered)
			row.Accuracy = &accuracy
		}
		feedback = append(feedback, row)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	config, err := loadSkillRegistry(ctx, conn, actor)
	if err != nil {
		return feedback, nil, nil
	}
	skills := &aiOpsSkills{Generation: config.Generation, Items: []aiOpsSkill{}}
	for _, item := range skillDefinitions {
		skills.Items = append(skills.Items, aiOpsSkill{item.id, item.purpose, item.version, config.Registry.enabled[item.id]})
	}
	return feedback, skills, nil
}

type aiOpsModel struct {
	Purpose string  `json:"purpose"`
	Node    *string `json:"provider_id"`
	Model   *string `json:"model_id"`
	Version *string `json:"model_version"`
	State   string  `json:"state"`
}

type aiOpsIndex struct {
	Points      int64   `json:"point_count"`
	Phase       *string `json:"phase"`
	LastSuccess *int64  `json:"last_success_at"`
	Next        *int64  `json:"next_at"`
}

func readOpsJSON(ctx context.Context, address, key string, timeoutMillis int, into any) bool {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(timeoutMillis)*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return false
	}
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	res, err := knowledgeIndexHTTP.Do(req)
	if err != nil {
		return false
	}
	defer res.Body.Close()
	return res.StatusCode == http.StatusOK && json.NewDecoder(io.LimitReader(res.Body, 1048576)).Decode(into) == nil
}

func readOpsIndex(ctx context.Context) *aiOpsIndex {
	address := strings.TrimRight(os.Getenv("AI_KNOWLEDGE_INDEX_URL"), "/")
	key := os.Getenv("AI_INDEX_SERVICE_TOKEN")
	if !ai.ValidHTTPBaseURL(address) || len(key) < 32 {
		return nil
	}
	var result struct {
		Version int
		Ready   bool
		Status  *aiOpsIndex
	}
	if !readOpsJSON(ctx, address+aiOpsContract.IndexStatusPath, key, aiOpsContract.IndexTimeoutMilliseconds, &result) ||
		result.Version != 1 || !result.Ready {
		return nil
	}
	if result.Status != nil && result.Status.Phase != nil {
		switch *result.Status.Phase {
		case "syncing", "pruning", "waiting", "stopped":
		default:
			result.Status.Phase = nil
		}
	}
	return result.Status
}

func readOpsModels(ctx context.Context, config RefreshConfig) ([]aiOpsModel, []string, *int64) {
	results := make([]aiOpsModel, len(aiOpsContract.Roles))
	nodes := []string{}
	seen := map[string]bool{}
	router, _ := config.modelRouter()
	var revision *int64
	var wait sync.WaitGroup
	for i, purpose := range aiOpsContract.Roles {
		results[i] = aiOpsModel{Purpose: purpose, State: "unconfigured"}
		if router == nil {
			continue
		}
		role := purpose
		if purpose == "group" {
			role = "agent"
		}
		selected, err := router.Select(role, nil)
		if err != nil {
			continue
		}
		revision = &selected.ConfigurationRevision
		if !seen[selected.ProviderID] {
			seen[selected.ProviderID] = true
			nodes = append(nodes, selected.ProviderID)
		}
		results[i].Node, results[i].Model = &selected.ProviderID, &selected.ProfileID
		if selected.ModelVersion != "" {
			results[i].Version = &selected.ModelVersion
		}
		wait.Go(func() {
			results[i].State = probeOpsModel(ctx, selected, config)
		})
	}
	wait.Wait()
	return results, nodes, revision
}

func probeOpsModel(ctx context.Context, model ai.Selection, config RefreshConfig) string {
	key := ""
	if model.APIKeyEnv != nil {
		if config.aiCredential == nil {
			return "missing_credential"
		}
		var err error
		key, err = config.aiCredential(*model.APIKeyEnv)
		if err != nil || key == "" {
			return "missing_credential"
		}
	}
	var result struct {
		Data   []struct{ ID string }
		Models []struct{ Name string }
	}
	endpoint := "/models"
	if model.Adapter == "ollama" {
		endpoint = "/api/tags"
	}
	if !readOpsJSON(ctx, strings.TrimRight(model.BaseURL, "/")+endpoint, key, aiOpsContract.HealthTimeoutMilliseconds, &result) {
		return "unreachable"
	}
	for _, row := range result.Data {
		if row.ID == model.Model {
			return "ready"
		}
	}
	for _, row := range result.Models {
		if row.Name == model.Model {
			return "ready"
		}
	}
	return "model_unavailable"
}

func handleAIOperations(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	if r.Method != http.MethodGet || r.URL.EscapedPath() != "/api/v2/moderation/ai/operations" {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	actor, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	store, ok := repo.(aiOpsStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	ctx := r.Context()
	allowed, err := store.ModerationAllowed(ctx, actor, conversationPolicy(config.ModerationAllowAll, config.ModerationAdminAccounts))
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if !allowed {
		respond(w, 403, 40301, "需要审核权限", nil)
		return true
	}
	feedback, skills, err := store.ReadAIOps(ctx, actor)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	var models []aiOpsModel
	var nodes []string
	var revision *int64
	var index *aiOpsIndex
	quota := accountQuota{Window: aiQuotaContract.WindowMilliseconds / 1000}
	var wait sync.WaitGroup
	wait.Go(func() { models, nodes, revision = readOpsModels(ctx, config) })
	wait.Go(func() { index = readOpsIndex(ctx) })
	wait.Go(func() {
		limit := aiQuotaLimit(os.LookupEnv, "AI_QUOTA_SERVICE_PER_MINUTE", aiQuotaContract.ServiceLimit)
		if limiter, ok := config.AIModelQuotaLimiter.(*RedisAIModelQuota); ok {
			limit = limiter.totalLimit
			quota.Used = limiter.readQuotaUnits(ctx, "service")
		}
		if limit > 0 {
			quota.Limit = &limit
		}
	})
	wait.Wait()
	respond(w, 200, 200, "success", map[string]any{
		"backend": "go", "model_config_revision": revision, "models": models, "nodes": nodes,
		"global_quota": quota, "index": index, "feedback": feedback, "skills": skills,
	})
	return true
}
