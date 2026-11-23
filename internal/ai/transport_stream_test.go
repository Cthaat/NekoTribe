package ai

import (
	"errors"
	"strings"
	"testing"
)

func TestTransportStreaming(t *testing.T) {
	for _, tc := range []struct{ adapter, response string }{
		{"openai-compatible", "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"first\"}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\" second\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"},
		{"ollama", "{\"message\":{\"content\":\"first\"},\"done\":false}\n{\"message\":{\"content\":\" second\"},\"done\":true,\"done_reason\":\"stop\"}\n"},
	} {
		t.Run(tc.adapter, func(t *testing.T) {
			var deltas []string
			result, err := readProviderStream(strings.NewReader(tc.response), Selection{Adapter: tc.adapter}, false, func(text string) error {
				deltas = append(deltas, text)
				return nil
			})
			if err != nil || len(deltas) != 2 || result.Text != "first second" || result.FinishReason != "stop" {
				t.Fatalf("got %q with %d deltas: %v", result.Text, len(deltas), err)
			}
			_, err = readProviderStream(strings.NewReader(tc.response), Selection{Adapter: tc.adapter}, false, func(string) error { return ErrCancelled })
			if !errors.Is(err, ErrCancelled) {
				t.Fatal(err)
			}
		})
	}
}
