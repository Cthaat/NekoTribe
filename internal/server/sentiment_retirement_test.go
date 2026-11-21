package server

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"os"
	"testing"
)

func TestRetiredSentimentUsesLocalFixedResponses(t *testing.T) {
	app := NewHandler(nil, nil, CorsPolicy{})
	raw, err := os.ReadFile("../../contracts/scenarios/sentiment-retirement.json")
	if err != nil {
		t.Fatal(err)
	}
	var scenarios struct {
		Cases []struct {
			ID, Method, Path string
			Status, Code     int
		}
	}
	if err := json.Unmarshal(raw, &scenarios); err != nil {
		t.Fatal(err)
	}
	for _, scenario := range scenarios.Cases {
		t.Run(scenario.ID, func(t *testing.T) {
			request := httptest.NewRequest(scenario.Method, scenario.Path, bytes.NewBufferString("{"))
			request.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			app.ServeHTTP(w, request)
			if w.Code != scenario.Status || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("%d: %s", w.Code, w.Body.String())
			}
			var response struct {
				Code       int
				Message    string
				Data, Meta json.RawMessage
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if response.Code != scenario.Code || string(response.Meta) != "null" {
				t.Fatal(w.Body.String())
			}
			if scenario.Status == 200 {
				var actual, expected bytes.Buffer
				if json.Compact(&actual, response.Data) != nil || json.Compact(&expected, sentimentRetirement.Config) != nil ||
					actual.String() != expected.String() {
					t.Fatal(w.Body.String())
				}
			} else if string(response.Data) != "null" || (scenario.Status == 410 && response.Message != sentimentRetirement.RetiredMessage) {
				t.Fatal(w.Body.String())
			}
		})
	}
}
