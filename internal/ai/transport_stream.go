package ai

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

const streamFrameLimit = 65536

type deltaListenerKey struct{}
type DeltaListener func(string) error

func WithStreamDeltas(ctx context.Context, listener DeltaListener) context.Context {
	return context.WithValue(ctx, deltaListenerKey{}, listener)
}

func readProviderStream(body io.Reader, selection Selection, structured bool, emit DeltaListener) (InferenceResult, error) {
	openai := selection.Adapter == "openai-compatible"
	limited := &io.LimitedReader{R: body, N: transportLimit + 1}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 4096), streamFrameLimit+2)
	var text, frame strings.Builder
	var reason, usage any
	var final map[string]any
	terminal := false
	record := func(payload string) error {
		if openai && payload == "[DONE]" {
			terminal = true
			return nil
		}
		var response map[string]any
		if json.Unmarshal([]byte(payload), &response) != nil {
			return ErrInvalidProviderResponse
		}
		var fragment map[string]any
		if openai {
			if response["usage"] != nil {
				usage = response["usage"]
			}
			choices, ok := response["choices"].([]any)
			if !ok {
				return ErrInvalidProviderResponse
			}
			if len(choices) == 0 {
				return nil
			}
			choice, ok := choices[0].(map[string]any)
			if !ok || choice["index"] != float64(0) {
				return ErrInvalidProviderResponse
			}
			fragment, _ = choice["delta"].(map[string]any)
			if choice["finish_reason"] != nil {
				reason = choice["finish_reason"]
			}
		} else {
			fragment, _ = response["message"].(map[string]any)
			if response["done"] == true {
				terminal, final = true, response
			}
		}
		if fragment == nil || fragment["tool_calls"] != nil {
			return ErrInvalidProviderResponse
		}
		if delta, _ := fragment["content"].(string); delta != "" {
			text.WriteString(delta)
			if emit(delta) != nil {
				return ErrCancelled
			}
		}
		return nil
	}
	for !terminal && scanner.Scan() {
		line := scanner.Text()
		if len(line) > streamFrameLimit || limited.N == 0 {
			return InferenceResult{}, ErrResponseTooLarge
		}
		if !openai {
			if strings.TrimSpace(line) != "" {
				if err := record(line); err != nil {
					return InferenceResult{}, err
				}
			}
		} else if data, ok := strings.CutPrefix(line, "data:"); ok {
			if frame.Len()+len(line)+1 > streamFrameLimit {
				return InferenceResult{}, ErrResponseTooLarge
			}
			frame.WriteString(strings.TrimPrefix(data, " "))
			frame.WriteByte('\n')
		} else if line == "" && frame.Len() > 0 {
			if err := record(strings.TrimSuffix(frame.String(), "\n")); err != nil {
				return InferenceResult{}, err
			}
			frame.Reset()
		}
	}
	if err := scanner.Err(); err != nil {
		if errors.Is(err, bufio.ErrTooLong) {
			return InferenceResult{}, ErrResponseTooLarge
		}
		return InferenceResult{}, ErrProviderUnavailable
	}
	if openai && !terminal && frame.Len() > 0 {
		if err := record(strings.TrimSuffix(frame.String(), "\n")); err != nil {
			return InferenceResult{}, err
		}
	}
	if !terminal {
		return InferenceResult{}, ErrInvalidProviderResponse
	}
	message := map[string]any{"role": "assistant", "content": text.String()}
	if openai {
		final = map[string]any{"choices": []any{map[string]any{
			"index": 0, "finish_reason": reason, "message": message,
		}}, "usage": usage}
	} else {
		final["message"] = message
	}
	encoded, err := json.Marshal(final)
	if err != nil {
		return InferenceResult{}, ErrInvalidProviderResponse
	}
	return normalizeTransport(selection, encoded, nil, structured)
}
