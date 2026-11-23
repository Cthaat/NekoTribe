package server

import (
	"context"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type aiAvailability struct {
	Knowledge  bool `json:"knowledge"`
	Writing    bool `json:"writing"`
	Group      bool `json:"group"`
	Moderation bool `json:"moderation"`
}

type aiAvailabilityResponse struct {
	aiAvailability
	Inference           aiAvailability     `json:"inference"`
	ModelConfigRevision *int64             `json:"model_config_revision"`
	Skills              []aiAvailableSkill `json:"skills"`
}

type aiAvailableSkill struct {
	ID                string `json:"id"`
	Purpose           string `json:"purpose"`
	Version           int    `json:"version"`
	Enabled           bool   `json:"enabled"`
	ExplicitSelection bool   `json:"explicit_selection,omitempty"`
}

func availableSkillMetadata(flags aiAvailability) []aiAvailableSkill {
	enabled := map[string]bool{
		"knowledge": flags.Knowledge, "writing": flags.Writing,
		"group": flags.Group, "moderation": flags.Moderation,
	}
	skills := make([]aiAvailableSkill, 0, len(skillDefinitions))
	for _, item := range skillDefinitions {
		skills = append(skills, aiAvailableSkill{
			ID: item.id, Purpose: item.purpose, Version: item.version, Enabled: enabled[item.purpose],
			ExplicitSelection: true,
		})
	}
	return skills
}

func inferenceAvailability(config RefreshConfig, skills aiAvailability) (aiAvailability, *int64) {
	router, err := config.modelRouter()
	if err != nil {
		return aiAvailability{}, nil
	}
	selection, err := router.Select("knowledge", nil)
	if err != nil || selection.ConfigurationRevision > 999999999999999 {
		return aiAvailability{}, nil
	}
	configured := func(role string) bool {
		model, err := router.Select(role, nil)
		if err != nil {
			return false
		}
		if model.APIKeyEnv == nil {
			return true
		}
		if config.aiCredential == nil {
			return false
		}
		key, err := config.aiCredential(*model.APIKeyEnv)
		if err != nil || len(key) == 0 {
			return false
		}
		for i := 0; i < len(key); i++ {
			if key[i] < 0x21 || key[i] > 0x7e {
				return false
			}
		}
		return true
	}
	return aiAvailability{
		Knowledge: skills.Knowledge && configured("knowledge"), Writing: skills.Writing && configured("writing"),
		Group: skills.Group && configured("agent"), Moderation: skills.Moderation && configured("moderation"),
	}, &selection.ConfigurationRevision
}

type aiAvailabilityStore interface {
	readAIAvailability(context.Context, int64) (aiAvailability, error)
}

func (s OracleSessions) readAIAvailability(ctx context.Context, actor int64) (result aiAvailability, err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return result, errSkillConfigUnavailable
	}
	defer func() {
		if conn.Close() != nil {
			result = aiAvailability{}
			err = errSkillConfigUnavailable
		}
	}()
	config, e := loadSkillRegistry(ctx, conn, actor)
	if e != nil {
		return result, errSkillConfigUnavailable
	}
	enabled := func(purpose string) bool {
		item, _ := skillForPurpose(purpose)
		return config.Registry.enabled[item.id]
	}
	return aiAvailability{
		Knowledge: enabled("knowledge"), Writing: enabled("writing"),
		Group: enabled("group"), Moderation: enabled("moderation"),
	}, nil
}

func aiAvailabilityRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	if r.URL.EscapedPath() != "/api/v2/ai/availability" {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	if r.Method != http.MethodGet {
		respond(w, 404, 40404, "API route not found", nil)
		return true
	}
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	store, ok := repository.(aiAvailabilityStore)
	if !ok {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return true
	}
	result, err := store.readAIAvailability(r.Context(), actor)
	if err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return true
	}
	inference, revision := inferenceAvailability(config, result)
	if result.Writing && config.userProvider.key != nil {
		personal, _, err := activeUserWritingProvider(r.Context(), repository, actor, config.userProvider)
		if err != nil {
			inference.Writing = false
		} else if personal != nil {
			inference.Writing = true
		}
	}
	respond(w, 200, 200, "success", aiAvailabilityResponse{
		aiAvailability: result, Inference: inference, ModelConfigRevision: revision, Skills: availableSkillMetadata(result),
	})
	return true
}
