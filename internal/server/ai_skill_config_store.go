package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

var errSkillConfigUnavailable = errors.New("SKILL_CONFIG_UNAVAILABLE")

type skillConfig struct {
	Generation int64
	Registry   *skillRegistry
	Enabled    []string
}
type configuredSkillSelection struct {
	Generation int64
	Skill      skillSelection
}

// Identity must already be authenticated by the caller. Never cache the row.
func loadSkillRegistry(ctx context.Context, conn knowledgeQueryer, actor int64) (skillConfig, error) {
	return readSkillRegistry(ctx, conn, actor, false)
}

// The caller owns the transaction and must finish it promptly, never spanning inference.
func lockSkillRegistry(ctx context.Context, tx *sql.Tx, actor int64) (skillConfig, error) {
	if tx == nil {
		return skillConfig{}, errSkillConfigUnavailable
	}
	return readSkillRegistry(ctx, tx, actor, true)
}

func readSkillRegistry(ctx context.Context, conn knowledgeQueryer, actor int64, lock bool) (skillConfig, error) {
	if actor < 1 || actor > 9007199254740991 {
		return skillConfig{}, errSkillConfigUnavailable
	}
	config, err := readSkillConfig(ctx, conn, lock)
	if err != nil || config.Generation == 0 {
		return skillConfig{}, errSkillConfigUnavailable
	}
	return config, nil
}

func verifySkillConfigSchema(ctx context.Context, conn knowledgeQueryer) error {
	var catalog schemaCatalog
	if json.Unmarshal(contracts.AISkillSchemaCatalog, &catalog) != nil || validateFeatureSchema(ctx, conn, catalog, "ai-skills") != nil {
		return errSkillConfigUnavailable
	}
	return nil
}

func readSkillConfig(ctx context.Context, conn knowledgeQueryer, lock bool) (skillConfig, error) {
	if err := verifySkillConfigSchema(ctx, conn); err != nil {
		return skillConfig{}, err
	}
	query := `SELECT generation,enabled_ids FROM n_ai_skill_config WHERE singleton_id=:singleton_id`
	if lock {
		query += ` FOR UPDATE NOWAIT`
	}
	rows, err := conn.QueryContext(ctx, query, sql.Named("singleton_id", 1))
	if err != nil {
		return skillConfig{}, errSkillConfigUnavailable
	}
	defer rows.Close()
	if !rows.Next() {
		if rows.Err() != nil || rows.Close() != nil {
			return skillConfig{}, errSkillConfigUnavailable
		}
		return skillConfig{}, nil
	}
	var generation int64
	var encoded string
	if rows.Scan(&generation, &encoded) != nil || rows.Next() || rows.Err() != nil || rows.Close() != nil || generation < 1 || generation > skillWrite.MaxGeneration || len(encoded) > 512 || !utf8.ValidString(encoded) {
		return skillConfig{}, errSkillConfigUnavailable
	}
	var enabled []string
	if json.Unmarshal([]byte(encoded), &enabled) != nil || enabled == nil {
		return skillConfig{}, errSkillConfigUnavailable
	}
	registry, err := newSkillRegistry(enabled)
	if err != nil {
		return skillConfig{}, errSkillConfigUnavailable
	}
	slices.Sort(enabled)
	return skillConfig{Generation: generation, Registry: registry, Enabled: enabled}, nil
}

// The caller supplies an authenticated identity and a dedicated transaction.
func selectConfiguredConversationSkill(ctx context.Context, tx *sql.Tx, actor int64, id string, skillID *string, policy moderationPolicy) (configuredSkillSelection, error) {
	if tx == nil || actor < 1 || actor > 9007199254740991 {
		return configuredSkillSelection{}, errSkillConfigUnavailable
	}
	config, err := loadSkillRegistry(ctx, tx, actor)
	if err != nil {
		return configuredSkillSelection{}, err
	}
	skill, err := selectConversationSkill(ctx, tx, config.Registry, actor, id, skillID, policy)
	if err != nil {
		return configuredSkillSelection{}, err
	}
	return configuredSkillSelection{Generation: config.Generation, Skill: skill}, nil
}

// The database connection and read transaction end before inference starts.
func (s OracleSessions) selectAIKnowledgeSkill(ctx context.Context, actor int64, id string, policy moderationPolicy, skillID *string) (int64, error) {
	return s.selectAISkillOperation(ctx, actor, id, policy, skillID, verifyConversationSchema)
}
func (s OracleSessions) selectAIWritingSkill(ctx context.Context, actor int64, id string, policy moderationPolicy, skillID *string) (int64, error) {
	return s.selectAISkillOperation(ctx, actor, id, policy, skillID, verifyConversationSchema)
}
func (s OracleSessions) selectAISkillOperation(ctx context.Context, actor int64, id string, policy moderationPolicy, skillID *string, verify func(context.Context, *sql.Conn) error) (generation int64, err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return 0, errSkillConfigUnavailable
	}
	defer func() {
		if conn.Close() != nil {
			generation = 0
			err = errSkillConfigUnavailable
		}
	}()
	if verify(ctx, conn) != nil {
		return 0, errConversationSchema
	}
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return 0, errSkillConfigUnavailable
	}
	defer func() {
		if tx.Rollback() != nil {
			generation = 0
			err = errSkillConfigUnavailable
		}
	}()
	selection, e := selectConfiguredConversationSkill(ctx, tx, actor, id, skillID, policy)
	if e != nil {
		return 0, e
	}
	return selection.Generation, nil
}
