package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type skillWriteContract struct {
	MaxGeneration int64 `json:"maxGeneration"`
	Queries       struct {
		Insert string `json:"insert"`
		Update string `json:"update"`
	} `json:"queries"`
}

var skillWrite = func() skillWriteContract {
	var spec skillWriteContract
	if json.Unmarshal(contracts.AISkillConfigWrite, &spec) != nil || spec.MaxGeneration < 1 ||
		spec.Queries.Insert == "" || spec.Queries.Update == "" {
		panic("invalid skill publication contract")
	}
	return spec
}()

var (
	errSkillArguments = errors.New("INVALID_ARGUMENTS")
	errSkillConflict  = errors.New("SKILL_CONFIG_CONFLICT")
	errSkillWrite     = errors.New("SKILL_CONFIG_WRITE_FAILED")
	errSkillCommit    = errors.New("SKILL_CONFIG_COMMIT_UNCERTAIN")
)

type skillCommand struct {
	mode     string
	expected *int64
	enabled  []string
}

func parseSkillCommand(args []string) (skillCommand, error) {
	cmd := skillCommand{}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--plan", "--status", "--publish":
			if cmd.mode != "" {
				return cmd, errSkillArguments
			}
			cmd.mode = arg[2:]
		case "--expected":
			i++
			if i == len(args) || cmd.expected != nil {
				return cmd, errSkillArguments
			}
			n, err := strconv.ParseInt(args[i], 10, 64)
			if err != nil || n < 0 || n >= skillWrite.MaxGeneration || strconv.FormatInt(n, 10) != args[i] {
				return cmd, errSkillArguments
			}
			cmd.expected = &n
		case "--enabled-json":
			i++
			if i == len(args) || cmd.enabled != nil || len(args[i]) > 512 ||
				json.Unmarshal([]byte(args[i]), &cmd.enabled) != nil {
				return cmd, errSkillArguments
			}
			if _, err := newSkillRegistry(cmd.enabled); err != nil {
				return cmd, errors.New("SKILL_CONFIG_INVALID_INPUT")
			}
		default:
			return cmd, errSkillArguments
		}
	}
	if cmd.mode == "" {
		cmd.mode = "plan"
	}
	switch cmd.mode {
	case "plan":
		if cmd.expected != nil {
			return cmd, errSkillArguments
		}
		if cmd.enabled == nil {
			cmd.enabled = []string{}
		}
	case "status":
		if cmd.expected != nil || cmd.enabled != nil {
			return cmd, errSkillArguments
		}
	case "publish":
		if cmd.expected == nil || cmd.enabled == nil {
			return cmd, errSkillArguments
		}
	}
	slices.Sort(cmd.enabled)
	return cmd, nil
}

func skillOracleConfig(lookup func(string) (string, bool)) (Config, error) {
	get := func(key string) string { return sharedNativeEnv(lookup, key) }
	c := Config{
		OracleHost: get("ORACLE_HOST"), OracleService: get("ORACLE_SERVICE_NAME"),
		OracleUser: get("ORACLE_USER"), OraclePassword: get("ORACLE_PASSWORD"),
		PoolMin: 0, PoolMax: 1,
	}
	port, err := configInt(get("ORACLE_PORT"), 1521, 1, 65535)
	if err != nil || strings.ContainsAny(c.OracleHost+c.OracleService, "()/= \t\r\n") {
		return Config{}, errConfig
	}
	for _, value := range []string{c.OracleHost, c.OracleService, c.OracleUser, c.OraclePassword} {
		if strings.TrimSpace(value) == "" {
			return Config{}, errConfig
		}
	}
	c.OraclePort = port
	return c, nil
}

// RunSkillMaintenance uses a dedicated connection only in explicit connected modes.
func RunSkillMaintenance(ctx context.Context, args []string, lookup func(string) (string, bool)) (result map[string]any, err error) {
	cmd, err := parseSkillCommand(args)
	if err != nil {
		return nil, err
	}
	if cmd.mode == "plan" {
		return map[string]any{"mode": "plan", "enabled": cmd.enabled, "connected": false}, nil
	}
	config, err := skillOracleConfig(lookup)
	if err != nil {
		return nil, errors.New("SKILL_CONFIG_CONFIGURATION_INVALID")
	}
	db, err := OpenOracle(config)
	if err != nil {
		return nil, errors.New("SKILL_CONFIG_OPERATION_FAILED")
	}
	defer func() {
		if CloseOracle(db) != nil {
			result, err = nil, errors.New("SKILL_CONFIG_CONNECTION_CLOSE_FAILED")
		}
	}()
	conn, err := db.Conn(ctx)
	if err != nil {
		return nil, errors.New("SKILL_CONFIG_OPERATION_FAILED")
	}
	defer func() {
		if conn.Close() != nil {
			result, err = nil, errors.New("SKILL_CONFIG_CONNECTION_CLOSE_FAILED")
		}
	}()
	if cmd.mode == "status" {
		config, err := readSkillConfig(ctx, conn, false)
		if err != nil {
			return nil, errors.New("SKILL_CONFIG_OPERATION_FAILED")
		}
		if config.Generation == 0 {
			return map[string]any{"mode": "status", "initialized": false}, nil
		}
		return map[string]any{"mode": "status", "generation": config.Generation, "enabled": config.Enabled}, nil
	}
	if err := verifySkillConfigSchema(ctx, conn); err != nil {
		return nil, errSkillWrite
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return nil, errSkillWrite
	}
	if err := publishSkillConfig(ctx, tx, *cmd.expected, cmd.enabled); err != nil {
		return nil, err
	}
	return map[string]any{"generation": *cmd.expected + 1, "enabled": cmd.enabled}, nil
}

func publishSkillConfig(ctx context.Context, tx *sql.Tx, expected int64, enabled []string) error {
	encoded, err := json.Marshal(enabled)
	if err != nil {
		_ = tx.Rollback()
		return errSkillWrite
	}
	query, binds := skillWrite.Queries.Insert, []any{sql.Named("enabled_ids", string(encoded))}
	if expected > 0 {
		query = skillWrite.Queries.Update
		binds = append(binds, sql.Named("expected_generation", expected))
	}
	written, err := tx.ExecContext(ctx, query, binds...)
	if err != nil {
		var unique interface{ ErrorCode() string }
		rolledBack := tx.Rollback() == nil
		if rolledBack && expected == 0 && errors.As(err, &unique) && unique.ErrorCode() == "ORA-00001" {
			return errSkillConflict
		}
		return errSkillWrite
	}
	count, countErr := written.RowsAffected()
	if countErr != nil || count != 1 {
		if tx.Rollback() == nil && countErr == nil && count == 0 {
			return errSkillConflict
		}
		return errSkillWrite
	}
	if tx.Commit() != nil {
		return errSkillCommit
	}
	return nil
}
