package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"testing"
)

func TestSharedSettingsReadiness(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/user-settings-readiness.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ID       string          `json:"id"`
		Baseline json.RawMessage `json:"baseline"`
		Cases    []struct {
			ID        string `json:"id"`
			Ready     bool   `json:"ready"`
			Mutations []struct {
				Op    string        `json:"op"`
				Path  []interface{} `json:"path"`
				Value interface{}   `json:"value"`
			} `json:"mutations"`
		} `json:"cases"`
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.ID != "USER-SETTINGS-READINESS" || len(fixture.Cases) != 8 {
		t.Fatal("invalid fixture")
	}
	for _, scenario := range fixture.Cases {
		t.Run(scenario.ID, func(t *testing.T) {
			var snapshot map[string]interface{}
			if err := json.Unmarshal(fixture.Baseline, &snapshot); err != nil {
				t.Fatal(err)
			}
			for _, m := range scenario.Mutations {
				snapshot = applySchemaMutation(snapshot, m.Path, m.Op, m.Value).(map[string]interface{})
			}
			var calls []string
			connections := 0
			db := sql.OpenDB(schemaFixtureConnector{snapshot, &calls, &connections})
			defer db.Close()
			err := (OracleSessions{db}).CheckUserSettingsSchema(context.Background())
			if (err == nil) != scenario.Ready || connections != 1 || len(calls) == 0 {
				t.Fatal(err, connections, calls)
			}
		})
	}
}
