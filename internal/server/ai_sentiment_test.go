package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func configuredSentimentForTest(t *testing.T) *sentimentClient {
	t.Helper()
	settings := map[string]string{"AI_SENTIMENTFLOW_ENABLED": "1", "AI_SENTIMENTFLOW_URL": "http://sentiment.example.test/internal/predict/", "AI_SENTIMENTFLOW_TOKEN": "test-token"}
	client := configuredSentiment(func(key string) string { return settings[key] })
	if client == nil {
		t.Fatal("valid optional configuration was disabled")
	}
	return client
}

func TestSentimentBatchUsesExactEndpointAndNormalizesLabels(t *testing.T) {
	client := configuredSentimentForTest(t)
	client.http.Transport = knowledgeIndexTransportFunc(func(request *http.Request) (*http.Response, error) {
		var body struct {
			Text                string `json:"text"`
			Model               string `json:"model"`
			ReturnProbabilities *bool  `json:"return_probabilities"`
			IncludeMetadata     *bool  `json:"include_metadata"`
		}
		if request.URL.Path != "/internal/predict/" || request.Method != http.MethodPost || request.Header.Get("Authorization") != "Bearer test-token" || json.NewDecoder(request.Body).Decode(&body) != nil || body.Model != "lstm" || body.ReturnProbabilities == nil || *body.ReturnProbabilities || body.IncludeMetadata == nil || *body.IncludeMetadata {
			t.Error("incorrect request")
		}
		if _, hasDeadline := request.Context().Deadline(); !hasDeadline {
			t.Error("prediction request lacks a shared deadline")
		}
		payload := `{"prediction":{"label":"slightly_positive","confidence":0.8}}`
		if body.Text == "first" {
			payload = `{"score":2,"confidence":0.6}`
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(payload))}, nil
	})
	signals, ok := client.predictBatch(context.Background(), []string{"first", "second"})
	if !ok || len(signals) != 2 || signals[0] != (sentimentSignal{Label: "negative", Confidence: 0.6}) || signals[1] != (sentimentSignal{Label: "positive", Confidence: 0.8}) {
		t.Fatal(signals, ok)
	}
}

func TestSentimentCircuitOpensAfterThreeFailedBatches(t *testing.T) {
	client := configuredSentimentForTest(t)
	var count atomic.Int64
	client.http.Transport = knowledgeIndexTransportFunc(func(request *http.Request) (*http.Response, error) {
		count.Add(1)
		return &http.Response{StatusCode: http.StatusTemporaryRedirect, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{"Location": {"http://different.example.test/"}}}, nil
	})
	for i := 0; i < 4; i++ {
		if result, ok := client.predictBatch(context.Background(), []string{"example"}); ok || result != nil {
			t.Fatal("a redirect or open circuit produced signals", result)
		}
	}
	if count.Load() != 3 {
		t.Fatal("unexpected call count", count.Load())
	}
}

func TestSentimentBatchUsesOneAbsoluteTimeout(t *testing.T) {
	client := configuredSentimentForTest(t)
	deadlines := make(chan time.Time, 2)
	client.http.Transport = knowledgeIndexTransportFunc(func(request *http.Request) (*http.Response, error) {
		deadline, _ := request.Context().Deadline()
		deadlines <- deadline
		<-request.Context().Done()
		return nil, request.Context().Err()
	})
	started := time.Now()
	result, ok := client.predictBatch(context.Background(), []string{"first", "second"})
	if ok || result != nil || len(deadlines) != 2 {
		t.Fatal(result, ok, len(deadlines))
	}
	first, second := <-deadlines, <-deadlines
	if !first.Equal(second) || first.Before(started) || first.Sub(started) > 1250*time.Millisecond {
		t.Fatal("predictions did not share the absolute deadline", first.Sub(started), second.Sub(started))
	}
}
