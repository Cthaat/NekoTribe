package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type sentimentDefinition struct {
	Tool            groupDraftTool      `json:"tool"`
	Labels          map[string][]string `json:"labels"`
	OldScores       []string            `json:"old_scores"`
	TimeoutMS       int                 `json:"timeout_ms"`
	FailureLimit    int                 `json:"failure_limit"`
	CooldownMS      int                 `json:"cooldown_ms"`
	MaxReplyBytes   int64               `json:"max_reply_bytes"`
	SamplePerWindow int                 `json:"sample_per_window"`
	MaxSamples      int                 `json:"max_samples"`
	QueuePostQuery  string              `json:"queue_post_query"`
}

var sentimentContract = func() sentimentDefinition {
	var definition sentimentDefinition
	if json.Unmarshal(contracts.AISentiment, &definition) != nil || definition.Tool.Name == "" || definition.QueuePostQuery == "" ||
		len(definition.OldScores) != 6 || definition.MaxSamples != 8 || definition.SamplePerWindow != 4 ||
		definition.TimeoutMS <= 0 || definition.FailureLimit <= 0 || definition.CooldownMS <= 0 || definition.MaxReplyBytes <= 0 {
		panic("invalid AI sentiment contract")
	}
	return definition
}()

var sentimentLabels = func() map[string]string {
	labels := map[string]string{}
	for normalized, values := range sentimentContract.Labels {
		for _, label := range values {
			labels[label] = normalized
		}
	}
	return labels
}()

var errSentimentUnavailable = errors.New("sentiment signal unavailable")

type sentimentSignal struct {
	Label      string  `json:"label"`
	Confidence float64 `json:"confidence"`
}

type sentimentClient struct {
	endpoint, token string
	http            *http.Client
	mutex           sync.Mutex
	failedBatches   int
	openUntil       time.Time
	epoch           uint64
}

func configuredSentiment(get func(string) string) *sentimentClient {
	if get("AI_SENTIMENTFLOW_ENABLED") != "1" {
		return nil
	}
	endpoint := strings.TrimSpace(get("AI_SENTIMENTFLOW_URL"))
	token := get("AI_SENTIMENTFLOW_TOKEN")
	if len(endpoint) > 2048 || !ai.ValidHTTPBaseURL(endpoint) || len(token) > 4096 || strings.ContainsFunc(token, func(r rune) bool { return r < '!' || r > '~' }) {
		return nil
	}
	return &sentimentClient{endpoint: endpoint, token: token, http: &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func sentimentTimeout() time.Duration {
	return time.Duration(sentimentContract.TimeoutMS) * time.Millisecond
}

func validSentimentExcerpt(text string) bool {
	return strings.TrimFunc(text, jsTrimSpace) != "" && utf8.ValidString(text) && utf8.RuneCountInString(text) <= 400
}

func (c *sentimentClient) available() bool {
	if c == nil {
		return false
	}
	c.mutex.Lock()
	defer c.mutex.Unlock()
	return !c.openUntil.After(time.Now())
}

func (c *sentimentClient) beginBatch() (uint64, bool) {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	if c.openUntil.After(time.Now()) {
		return 0, false
	}
	if !c.openUntil.IsZero() {
		c.openUntil = time.Time{}
		c.failedBatches = 0
	}
	return c.epoch, true
}

func (c *sentimentClient) finishBatch(epoch uint64, success bool) {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	if epoch != c.epoch {
		return
	}
	if success {
		c.failedBatches = 0
		return
	}
	c.failedBatches++
	if c.failedBatches >= sentimentContract.FailureLimit {
		c.openUntil = time.Now().Add(time.Duration(sentimentContract.CooldownMS) * time.Millisecond)
		c.epoch++
	}
}

func (c *sentimentClient) predictBatch(ctx context.Context, texts []string) ([]sentimentSignal, bool) {
	if c == nil || ctx.Err() != nil || len(texts) == 0 || len(texts) > sentimentContract.MaxSamples {
		return nil, false
	}
	for _, text := range texts {
		if !validSentimentExcerpt(text) {
			return nil, false
		}
	}
	epoch, allowed := c.beginBatch()
	if !allowed {
		return nil, false
	}
	batch, cancel := context.WithTimeout(ctx, sentimentTimeout())
	defer cancel()
	signals := make([]sentimentSignal, len(texts))
	var workers sync.WaitGroup
	for i, text := range texts {
		workers.Go(func() {
			signal, err := c.predict(batch, text)
			if err != nil {
				cancel()
				return
			}
			signals[i] = signal
		})
	}
	workers.Wait()
	success := batch.Err() == nil
	if !errors.Is(ctx.Err(), context.Canceled) {
		c.finishBatch(epoch, success)
	}
	if !success {
		return nil, false
	}
	return signals, true
}

func (c *sentimentClient) predict(ctx context.Context, text string) (sentimentSignal, error) {
	body, err := json.Marshal(struct {
		Text                string `json:"text"`
		Model               string `json:"model"`
		ReturnProbabilities bool   `json:"return_probabilities"`
		IncludeMetadata     bool   `json:"include_metadata"`
	}{Text: text, Model: "lstm"})
	if err != nil {
		return sentimentSignal{}, errSentimentUnavailable
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return sentimentSignal{}, errSentimentUnavailable
	}
	request.GetBody = nil
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept-Encoding", "identity")
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	response, err := c.http.Do(request)
	if err != nil {
		return sentimentSignal{}, errSentimentUnavailable
	}
	defer response.Body.Close()
	encoding := response.Header.Get("Content-Encoding")
	if response.StatusCode < 200 || response.StatusCode >= 300 || (encoding != "" && !strings.EqualFold(encoding, "identity")) {
		return sentimentSignal{}, errSentimentUnavailable
	}
	payload, err := io.ReadAll(io.LimitReader(response.Body, sentimentContract.MaxReplyBytes+1))
	if err != nil || int64(len(payload)) > sentimentContract.MaxReplyBytes {
		return sentimentSignal{}, errSentimentUnavailable
	}
	return parseSentimentSignal(payload)
}

func parseSentimentSignal(payload []byte) (sentimentSignal, error) {
	decoded, valid := ai.DecodeScalarJSON(payload, 16)
	data, object := decoded.(map[string]any)
	if !valid || !object {
		return sentimentSignal{}, errSentimentUnavailable
	}
	if envelope, present := data["data"]; present {
		data, object = envelope.(map[string]any)
		if !object {
			return sentimentSignal{}, errSentimentUnavailable
		}
	}
	prediction, nested := data["prediction"]
	if nested {
		data, object = prediction.(map[string]any)
		if !object {
			return sentimentSignal{}, errSentimentUnavailable
		}
	}
	label := ""
	if raw, present := data["label"]; present {
		text, _ := raw.(string)
		label = sentimentLabels[text]
	} else if !nested {
		if score, numeric := data["score"].(float64); numeric && score >= 0 && score < float64(len(sentimentContract.OldScores)) && score == float64(int(score)) {
			label = sentimentContract.OldScores[int(score)]
		}
	}
	confidence, numeric := data["confidence"].(float64)
	if label == "" || !numeric || confidence < 0 || confidence > 1 {
		return sentimentSignal{}, errSentimentUnavailable
	}
	return sentimentSignal{Label: label, Confidence: confidence}, nil
}
