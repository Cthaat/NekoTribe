package ai

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
)

type scenario struct {
	ID                   string          `json:"id"`
	Action               string          `json:"action"`
	Config               json.RawMessage `json:"config"`
	NextConfig           json.RawMessage `json:"nextConfig"`
	ExpectedRevision     int64           `json:"expectedRevision"`
	Role                 string          `json:"role"`
	RequiredCapabilities []string        `json:"requiredCapabilities"`
	Expected             json.RawMessage `json:"expected"`
	ExpectedBefore       json.RawMessage `json:"expectedBefore"`
	ExpectedAfterError   json.RawMessage `json:"expectedAfterError"`
	ExpectedError        string          `json:"expectedError"`
}

func TestRejectMalformedConfiguration(t *testing.T) {
	base := string(scenarios(t)[0].Config)
	changes := []struct{ name, old, next string }{
		{"case-sensitive-root", `"schemaVersion"`, `"SchemaVersion"`},
		{"unknown-root", `"schemaVersion": 1`, `"secret": "DO_NOT_ECHO", "schemaVersion": 1`},
		{"unknown-model-field", `"model": "test/local-v1"`, `"apiKey": "DO_NOT_ECHO", "model": "test/local-v1"`},
		{"case-sensitive-provider", `"baseUrl"`, `"BaseURL"`},
		{"null-capabilities", `"capabilities": []`, `"capabilities": null`},
		{"repeated-capability", `"capabilities": []`, `"capabilities": ["vision", "vision"]`},
		{"zero-revision", `"revision": 1`, `"revision": 0`},
		{"unsafe-revision", `"revision": 1`, `"revision": 9007199254740992`},
		{"fraction-revision", `"revision": 1`, `"revision": 1.5`},
		{"string-revision", `"revision": 1`, `"revision": "1"`},
		{"zero-tokens", `"maxOutputTokens": 512`, `"maxOutputTokens": 0`},
		{"oversized-tokens", `"contextWindowTokens": 4096`, `"contextWindowTokens": 2147483648`},
		{"equal-tokens", `"maxOutputTokens": 512`, `"maxOutputTokens": 4096`},
		{"trimmed-model", `"test/local-v1"`, `" test/local-v1"`},
		{"oversized-unicode-model", `"test/local-v1"`, `"` + strings.Repeat("猫", 257) + `"`},
	}
	for _, tc := range changes {
		t.Run(tc.name, func(t *testing.T) {
			if !strings.Contains(base, tc.old) {
				t.Fatalf("fixture does not contain %s", tc.old)
			}
			router, err := NewModelRouter([]byte(strings.Replace(base, tc.old, tc.next, 1)))
			if router != nil || !errors.Is(err, ErrInvalidConfiguration) || err.Error() != "INVALID_CONFIGURATION" {
				t.Fatalf("want safe invalid configuration, got %v", err)
			}
		})
	}
	for _, input := range []string{"null", "[]", "{}", base + "{}", "{", `{"schemaVersion":null}`} {
		if _, err := NewModelRouter([]byte(input)); !errors.Is(err, ErrInvalidConfiguration) {
			t.Fatalf("malformed input was accepted: %v", err)
		}
	}
}

func TestProviderURLBoundaries(t *testing.T) {
	base := string(scenarios(t)[0].Config)
	for _, value := range []string{
		"HTTP://example.test", "https://user:DO_NOT_ECHO@example.test", "http://example.test?", "http://example.test#", "http://example.test/#DO_NOT_ECHO", "http://example.test/a b", "http://example.test:0", "http://example.test:65536", "http://example.test:", "http://example.test:abc", "http://-example.test", "http://example..test", "http://[example.test]", "http://", "http://example.test/\u2003",
		"http://127.0.0.1.", "http://127.000.0.1", "http://0x7f000001", "http://2130706433", "http://service.123", "http://service.0xFF", "http://[127.0.0.1]", "http://[fe80::1%25eth0]", "http://::1", "http://example.test/\u0000", "http://example.test/\u007f", "http://example.test/a\\b",
	} {
		t.Run(value, func(t *testing.T) {
			encoded, err := json.Marshal(value)
			if err != nil {
				t.Fatal(err)
			}
			input := strings.Replace(base, `"http://127.0.0.1:11434"`, string(encoded), 1)
			if _, err := NewModelRouter([]byte(input)); !errors.Is(err, ErrInvalidConfiguration) {
				t.Fatalf("want safe invalid configuration, got %v", err)
			}
		})
	}
	for _, value := range []string{"http://localhost:1", "https://example.test:65535/a//", "http://[::1]:11434", "http://127.0.0.1:11434", "http://ai_service:8000/v1/", "http://_service_:8000", "https://example.test./v1", "https://xn--fsqu00a.example.test"} {
		input := strings.Replace(base, "http://127.0.0.1:11434", value, 1)
		router, err := NewModelRouter([]byte(input))
		if err != nil {
			t.Fatalf("valid URL rejected: %v", err)
		}
		selection, err := router.Select("knowledge", nil)
		if err != nil {
			t.Fatal(err)
		}
		if selection.BaseURL != strings.TrimRight(value, "/") {
			t.Fatal("URL text was rewritten")
		}
	}
}

func TestSelectionRequestValidation(t *testing.T) {
	router, err := NewModelRouter(scenarios(t)[0].Config)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range [][]string{{"tools", "tools"}, {"audio"}, {""}, {"vision"}} {
		if _, err := router.Select("knowledge", required); !errors.Is(err, ErrUnsupportedCapability) {
			t.Fatalf("want unsupported capability, got %v", err)
		}
	}
	if _, err := router.Select("AGENT", []string{"audio"}); !errors.Is(err, ErrUnknownRole) {
		t.Fatalf("role must be validated first: %v", err)
	}
}

func TestOptionalEnvironmentReferenceAndIntegralNumbers(t *testing.T) {
	base := string(scenarios(t)[0].Config)
	for _, value := range []string{`null`, `""`} {
		input := strings.Replace(base, `"AI_HOSTED_KEY"`, value, 1)
		router, err := NewModelRouter([]byte(input))
		if err != nil {
			t.Fatal(err)
		}
		selection, err := router.Select("agent", nil)
		if err != nil {
			t.Fatal(err)
		}
		if selection.APIKeyEnv != nil {
			t.Fatal("empty environment reference must be null")
		}
	}
	input := strings.Replace(base, `"AI_HOSTED_KEY"`, `" "`, 1)
	if _, err := NewModelRouter([]byte(input)); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("whitespace reference must be rejected: %v", err)
	}
	input = strings.Replace(base, `"revision": 1`, `"revision": 1e0`, 1)
	input = strings.Replace(input, `"schemaVersion": 1`, `"schemaVersion": 1.0`, 1)
	if _, err := NewModelRouter([]byte(input)); err != nil {
		t.Fatalf("integral JSON numeric forms must be accepted: %v", err)
	}
	input = strings.Replace(base, "test/local-v1", strings.Repeat("猫", 256), 1)
	if _, err := NewModelRouter([]byte(input)); err != nil {
		t.Fatalf("256 Unicode characters must be accepted: %v", err)
	}
}

func TestReplacementErrorPrecedence(t *testing.T) {
	router, err := NewModelRouter(scenarios(t)[0].Config)
	if err != nil {
		t.Fatal(err)
	}
	if err := router.Replace([]byte("malformed DO_NOT_ECHO"), 0); !errors.Is(err, ErrStaleConfiguration) {
		t.Fatalf("stale check must precede parsing: %v", err)
	}
	if err := router.Replace([]byte("malformed DO_NOT_ECHO"), 1); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("matching revision must parse: %v", err)
	}
	invalidOld := strings.Replace(string(scenarios(t)[0].Config), `"agent": "capable"`, `"agent": "missing"`, 1)
	if err := router.Replace([]byte(invalidOld), 1); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("validation must precede revision reuse: %v", err)
	}
}

func TestConcurrentCompareAndReplace(t *testing.T) {
	cases := scenarios(t)
	base := cases[0].Config
	router, err := NewModelRouter(base)
	if err != nil {
		t.Fatal(err)
	}
	next := []byte(strings.Replace(string(base), `"revision": 1`, `"revision": 2`, 1))
	start := make(chan struct{})
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() { <-start; results <- router.Replace(next, 1) }()
	}
	close(start)
	first, second := <-results, <-results
	if !((first == nil && errors.Is(second, ErrStaleConfiguration)) || (second == nil && errors.Is(first, ErrStaleConfiguration))) {
		t.Fatalf("want one success and one stale replacement: %v, %v", first, second)
	}
}

func TestConcurrentSelectionsObserveWholeRevisions(t *testing.T) {
	base := string(scenarios(t)[0].Config)
	router, err := NewModelRouter([]byte(base))
	if err != nil {
		t.Fatal(err)
	}
	var readers sync.WaitGroup
	for i := 0; i < 4; i++ {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for n := 0; n < 200; n++ {
				snapshot, err := router.Select("knowledge", nil)
				if err != nil {
					t.Error(err)
					return
				}
				if snapshot.Model != fmt.Sprintf("test/local-v%d", snapshot.ConfigurationRevision) {
					t.Error("observed mixed revision and model")
					return
				}
			}
		}()
	}
	for revision := int64(2); revision <= 30; revision++ {
		next := strings.Replace(base, `"revision": 1`, fmt.Sprintf(`"revision": %d`, revision), 1)
		next = strings.Replace(next, "test/local-v1", fmt.Sprintf("test/local-v%d", revision), 1)
		if err := router.Replace([]byte(next), revision-1); err != nil {
			t.Fatal(err)
		}
	}
	readers.Wait()
}

func scenarios(t *testing.T) []scenario {
	t.Helper()
	data, err := os.ReadFile("../../contracts/scenarios/ai-model-config.json")
	if err != nil {
		t.Fatal(err)
	}
	var suite struct {
		Cases []scenario `json:"cases"`
	}
	if err := json.Unmarshal(data, &suite); err != nil {
		t.Fatal(err)
	}
	if len(suite.Cases) != 52 {
		t.Fatalf("want 52 portable cases, got %d", len(suite.Cases))
	}
	return suite.Cases
}

func equalSelection(t *testing.T, got Selection, expected json.RawMessage) {
	t.Helper()
	var want Selection
	if err := json.Unmarshal(expected, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("selection mismatch: got %+v; want %+v", got, want)
	}
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	var gotFields, wantFields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &gotFields); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(expected, &wantFields); err != nil {
		t.Fatal(err)
	}
	if len(gotFields) != len(wantFields) {
		t.Fatal("selection JSON field count differs")
	}
	for key := range wantFields {
		if _, ok := gotFields[key]; !ok {
			t.Fatalf("missing JSON field %s", key)
		}
	}
}

func TestPortableModelConfiguration(t *testing.T) {
	for _, tc := range scenarios(t) {
		t.Run(tc.ID, func(t *testing.T) {
			router, err := NewModelRouter(tc.Config)
			if err != nil {
				if tc.ExpectedError != "INVALID_CONFIGURATION" || err.Error() != tc.ExpectedError {
					t.Fatalf("unexpected constructor error: %v", err)
				}
				return
			}
			if tc.Action == "replace" {
				before, err := router.Select(tc.Role, nil)
				if err != nil {
					t.Fatal(err)
				}
				if len(tc.ExpectedBefore) != 0 {
					equalSelection(t, before, tc.ExpectedBefore)
				}
				err = router.Replace(tc.NextConfig, tc.ExpectedRevision)
				if tc.ExpectedError != "" {
					if err == nil || err.Error() != tc.ExpectedError {
						t.Fatalf("want %s, got %v", tc.ExpectedError, err)
					}
					after, err := router.Select(tc.Role, nil)
					if err != nil {
						t.Fatal(err)
					}
					equalSelection(t, after, tc.ExpectedAfterError)
					if !reflect.DeepEqual(before, after) {
						t.Fatal("failed replacement changed configuration")
					}
					return
				}
				if err != nil {
					t.Fatal(err)
				}
				if len(tc.ExpectedBefore) != 0 {
					equalSelection(t, before, tc.ExpectedBefore)
				}
			}
			got, err := router.Select(tc.Role, tc.RequiredCapabilities)
			if tc.ExpectedError != "" {
				if err == nil || err.Error() != tc.ExpectedError {
					t.Fatalf("want %s, got %v", tc.ExpectedError, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			equalSelection(t, got, tc.Expected)
			if tc.Action == "isolation" {
				got.Capabilities[0] = "mutated"
				*got.APIKeyEnv = "MUTATED"
				got.Model = "mutated"
				for i := range tc.Config {
					tc.Config[i] = ' '
				}
				again, err := router.Select(tc.Role, nil)
				if err != nil {
					t.Fatal(err)
				}
				equalSelection(t, again, tc.Expected)
			}
		})
	}
}
