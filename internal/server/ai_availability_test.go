package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

type availabilityFixture struct {
	*aiHTTPFixture
	result  aiAvailability
	failure error
	calls   int
}

func (f *availabilityFixture) readAIAvailability(_ context.Context, _ int64) (aiAvailability, error) {
	f.calls++
	return f.result, f.failure
}

func TestAvailabilitySharedConfiguration(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/ai-availability.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ID    string `json:"id"`
		Cases []struct {
			ID            string         `json:"id"`
			Authenticated bool           `json:"authenticated"`
			Enabled       []string       `json:"enabled"`
			Unavailable   bool           `json:"unavailable"`
			Status        int            `json:"status"`
			Data          aiAvailability `json:"data"`
		} `json:"cases"`
	}
	if json.Unmarshal(raw, &fixture) != nil || fixture.ID != "AI-AVAILABILITY" {
		t.Fatal("bad fixture")
	}
	for _, tc := range fixture.Cases {
		if !tc.Authenticated {
			continue
		}
		t.Run(tc.ID, func(t *testing.T) {
			encoded, _ := json.Marshal(tc.Enabled)
			state := &skillConfigState{rows: [][]driver.Value{{int64(1), string(encoded)}}, fail: tc.Unavailable}
			db := sql.OpenDB(skillConfigConnector{state})
			defer db.Close()
			result, err := (OracleSessions{db}).readAIAvailability(context.Background(), 42)
			if (err == nil) != (tc.Status == 200) || (err == nil && result != tc.Data) {
				t.Fatal(result, err, tc)
			}
		})
	}
}
func TestAvailabilityRouteAuthenticationAndSafeErrors(t *testing.T) {
	codec, tokens := fixture(t)
	s := &availabilityFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, result: aiAvailability{Knowledge: true}}
	call := func(token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/api/v2/ai/availability", nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{}).ServeHTTP(w, r)
		return w
	}
	w := call("")
	if w.Code != 401 || s.calls != 0 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(w.Code, s.calls)
	}
	w = call(tokens["access-hs256"])
	if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(w.Code, w.Body.String())
	}
	var response struct {
		Data struct {
			aiAvailabilityResponse
			Skills []map[string]any `json:"skills"`
		} `json:"data"`
	}
	if json.Unmarshal(w.Body.Bytes(), &response) != nil || !response.Data.Knowledge || response.Data.Writing || response.Data.Inference != (aiAvailability{}) || !strings.Contains(w.Body.String(), `"inference"`) {
		t.Fatal(w.Body.String())
	}
	if !strings.Contains(w.Body.String(), `"model_config_revision":null`) {
		t.Fatal("missing unconfigured revision")
	}
	want := []map[string]any{
		{"id": "knowledge-answer", "purpose": "knowledge", "version": float64(1), "enabled": true, "explicit_selection": true},
		{"id": "writing-draft", "purpose": "writing", "version": float64(1), "enabled": false, "explicit_selection": true},
		{"id": "group-brief", "purpose": "group", "version": float64(1), "enabled": false, "explicit_selection": true},
		{"id": "moderation-advice", "purpose": "moderation", "version": float64(1), "enabled": false, "explicit_selection": true},
	}
	if !reflect.DeepEqual(response.Data.Skills, want) || s.calls != 1 {
		t.Fatal(response.Data.Skills, s.calls)
	}
	s.failure = errSkillConfigUnavailable
	w = call(tokens["access-hs256"])
	if w.Code != 503 || w.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(w.Body.String(), s.failure.Error()) {
		t.Fatal(w.Code, w.Body.String())
	}
}
