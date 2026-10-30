package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"testing"
)

func TestSharedAIConversationReadiness(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/ai-conversation-readiness.json")
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
	if json.Unmarshal(data, &fixture) != nil || fixture.ID != "AI-CONVERSATION-READINESS" || len(fixture.Cases) != 8 {
		t.Fatal("invalid fixture")
	}
	for _, tc := range fixture.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			var snapshot map[string]interface{}
			if json.Unmarshal(fixture.Baseline, &snapshot) != nil {
				t.Fatal("invalid baseline")
			}
			for _, mutation := range tc.Mutations {
				snapshot = applySchemaMutation(snapshot, mutation.Path, mutation.Op, mutation.Value).(map[string]interface{})
			}
			var calls []string
			connections := 0
			db := sql.OpenDB(schemaFixtureConnector{snapshot, &calls, &connections})
			defer db.Close()
			err := (OracleSessions{db}).CheckAIConversationSchema(context.Background())
			if (err == nil) != tc.Ready || connections != 1 || len(calls) == 0 {
				t.Fatal(err, connections, calls)
			}
		})
	}
}
