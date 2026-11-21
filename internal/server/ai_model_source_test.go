package server

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAIModelFileReload(t *testing.T) {
	const modelA = "fixture/model-a"
	const modelB = "fixture/model-b"
	const base = `{"schemaVersion":1,"revision":1,"providers":[{"id":"local","adapter":"ollama","baseUrl":"http://127.0.0.1:11434"}],"models":[{"id":"profile","providerId":"local","model":"fixture/model-a","capabilities":["tools","structured-output"],"contextWindowTokens":4096,"maxOutputTokens":512}],"bindings":{"knowledge":"profile","writing":"profile","agent":"profile","moderation":"profile"}}`
	source := &aiModelFile{path: filepath.Join(t.TempDir(), "models.json")}
	config := RefreshConfig{AIModelConfig: base, aiModelFile: source}
	if _, err := config.modelRouter(); err == nil {
		t.Fatal("configured file silently fell back to inline JSON")
	}
	publish := func(body string, want string, wantRevision int64) {
		t.Helper()
		if err := os.WriteFile(source.path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
		source.nextCheck = time.Time{}
		router, err := config.modelRouter()
		if err != nil {
			t.Fatal(err)
		}
		selection, err := router.Select("knowledge", nil)
		if err != nil || selection.Model != want || selection.ConfigurationRevision != wantRevision {
			t.Fatalf("unexpected model revision %d", selection.ConfigurationRevision)
		}
	}
	publish(base, modelA, 1)
	original, _ := config.modelRouter()
	versionB := strings.Replace(strings.Replace(base, `"revision":1`, `"revision":2`, 1), modelA, modelB, 1)
	publish(versionB, modelB, 2)
	selected, _ := original.Select("knowledge", nil)
	if selected.Model != modelA || selected.ConfigurationRevision != 1 {
		t.Fatal("active work no longer retains its original configuration")
	}
	publish("{", modelB, 2)
	publish(base, modelB, 2)
	publish(strings.Replace(base, `"revision":1`, `"revision":3`, 1), modelA, 3)
	if got, revision := inferenceAvailability(config, aiAvailability{Knowledge: true}); got != (aiAvailability{Knowledge: true}) || revision == nil || *revision != 3 {
		t.Fatal("unexpected generation availability after a file reload")
	}
	const keyReference = `"adapter":"ollama","apiKeyEnv":"AI_FIXTURE_KEY"`
	config = RefreshConfig{AIModelConfig: strings.Replace(base, `"adapter":"ollama"`, keyReference, 1)}
	if got, revision := inferenceAvailability(config, aiAvailability{Knowledge: true}); got.Knowledge || revision == nil || *revision != 1 {
		t.Fatal("a missing credential must disable generation")
	}
	config.aiCredential = func(string) (string, error) { return "fixture-key", nil }
	if got, _ := inferenceAvailability(config, aiAvailability{Knowledge: true}); got != (aiAvailability{Knowledge: true}) {
		t.Fatal("configured credentials should enable only the requested skill")
	}
}
