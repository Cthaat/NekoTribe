package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type userProviderAPIFixture struct {
	*writingFixture
	records      map[int64]userProviderRecord
	reads, saves int
	saved        *assistantMessageInput
	readErr      error
}

func (f *userProviderAPIFixture) readUserProvider(_ context.Context, actor int64) (*userProviderRecord, error) {
	f.reads++
	if f.readErr != nil {
		return nil, f.readErr
	}
	if record, found := f.records[actor]; found {
		return &record, nil
	}
	return nil, nil
}

func (f *userProviderAPIFixture) saveUserProvider(_ context.Context, actor int64, settings userProviderSettings, input userProviderInput) (userProviderRecord, error) {
	f.saves++
	var previous *userProviderRecord
	if record, found := f.records[actor]; found {
		previous = &record
	}
	record, err := settings.update(actor, input, previous)
	if err == nil {
		f.records[actor] = record
	}
	return record, err
}

func (f *userProviderAPIFixture) deleteUserProvider(_ context.Context, actor int64) error {
	delete(f.records, actor)
	return nil
}

func (f *userProviderAPIFixture) appendAIAssistantMessage(_ context.Context, _ int64, id string, input assistantMessageInput, _ moderationPolicy) (conversationMessage, error) {
	f.saved = &input
	return conversationMessage{ID: "result", ConversationID: id, SequenceNo: input.ExpectedSequence + 1, Role: "assistant"}, nil
}

func (*userProviderAPIFixture) readAIAvailability(context.Context, int64) (aiAvailability, error) {
	return aiAvailability{Writing: true}, nil
}

func TestUserProviderSavedTestWritingAndStaleDenials(t *testing.T) {
	const key = "synthetic-private-key"
	var models, writes, platformWrites atomic.Int64
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/models":
			models.Add(1)
			if r.Method != http.MethodGet || r.Header.Get("Authorization") != "Bearer "+key {
				t.Error("incorrect verification method or credential")
				w.WriteHeader(401)
				return
			}
			fmt.Fprint(w, `{"data":[{"id":"personal/model-1"}]}`)
		case "/v1/chat/completions":
			writes.Add(1)
			var input struct{ Model string }
			if json.NewDecoder(r.Body).Decode(&input) != nil {
				w.WriteHeader(400)
				return
			}
			switch input.Model {
			case "personal/model-1":
				if r.Header.Get("Authorization") != "Bearer "+key {
					t.Error("writing did not use the owner's saved credential")
				}
			case "test-model":
				platformWrites.Add(1)
				if r.Header.Get("Authorization") != "" {
					t.Error("platform writing used a present or removed personal key")
				}
			default:
				t.Error("unexpected writing model")
			}
			fmt.Fprint(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"草稿"}}]}`)
		default:
			t.Error("unexpected provider endpoint", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer provider.Close()
	settings := testUserProviderSettings(t, provider.URL+"/v1///")
	foreignKey := "synthetic-foreign-key"
	foreign, err := settings.update(43, userProviderInput{Preset: "provided", Model: "personal/model-1", Enabled: true, APIKey: &foreignKey}, nil)
	if err != nil {
		t.Fatal(err)
	}
	store := &userProviderAPIFixture{writingFixture: &writingFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, latest: 4, purpose: "writing"},
		records: map[int64]userProviderRecord{43: foreign}}
	codec, tokens := fixture(t)
	const providerPath = "/api/v2/users/me/ai-provider"
	const writingPath = "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/generate"
	call := func(config RefreshConfig, method, path, body string, status int) string {
		t.Helper()
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		NewHandlerWithConfig(codec, store, CorsPolicy{}, config).ServeHTTP(w, r)
		result := w.Body.String()
		if w.Code != status || w.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(result, key) || strings.Contains(result, foreignKey) || strings.Contains(result, "secret_box") || strings.Contains(result, "api_key") {
			t.Fatal(method, path, w.Code, "unexpected status or credential exposure")
		}
		if record := store.records[42]; record.SecretBox != "" && strings.Contains(result, record.SecretBox) {
			t.Fatal("ciphertext appeared in the response")
		}
		return result
	}
	config := RefreshConfig{userProvider: settings, AIModelQuotaLimiter: singleCallAIQuota{}}
	if body := call(config, http.MethodGet, providerPath, "", 200); !strings.Contains(body, `"config":null`) || !strings.Contains(body, `"setup_available":true`) {
		t.Fatal("empty actor config was not returned")
	}
	call(config, http.MethodPost, providerPath+"/test", "", 404)
	call(config, http.MethodPut, providerPath, `{"preset":"provided","model":"personal/model-1","enabled":false,"base_url":"https://bad.example.test"}`, 400)
	if store.saves != 0 || models.Load() != 0 {
		t.Fatal("invalid or missing config reached provider or storage")
	}
	call(config, http.MethodPut, providerPath, `{"preset":"provided","model":"personal/model-1","enabled":true}`, 400)
	call(config, http.MethodPut, providerPath, `{"preset":"provided","model":"personal/model-1","enabled":false,"api_key":"`+key+`"}`, 200)
	box := store.records[42].SecretBox
	if body := call(config, http.MethodPost, providerPath+"/test", "", 200); !strings.Contains(body, `"verified":true`) {
		t.Fatal("saved disabled connection was not verified")
	}
	call(config, http.MethodPut, providerPath, `{"preset":"provided","model":"personal/model-1","enabled":true}`, 200)
	if record := store.records[42]; record.Revision != 2 || record.SecretBox != box {
		t.Fatal("the unchanged URL did not retain its encrypted key")
	}
	call(config, http.MethodPost, writingPath, `{"skill_id":"writing-draft","expected_sequence":4}`, 200)
	if store.saved == nil || store.saved.ModelID != "personal-writing" || store.saved.ConfigRevision != 2 || store.saved.SkillGeneration != 7 || writes.Load() != 1 || models.Load() != 1 {
		t.Fatal("generation did not retain its personal model revision and skill")
	}
	if body := call(config, http.MethodGet, "/api/v2/ai/availability", "", 200); !strings.Contains(body, `"inference":{"knowledge":false,"writing":true`) {
		t.Fatal("personal writing was not counted as available")
	}
	stale := config
	stale.userProvider = testUserProviderSettings(t, "http://other.example.test/v1")
	stale.AIModelConfig = writingConfig(provider.URL)
	if body := call(stale, http.MethodGet, providerPath, "", 200); !strings.Contains(body, `"reconnect_required":true`) {
		t.Fatal("preset drift did not require reconnecting")
	}
	call(stale, http.MethodPost, providerPath+"/test", "", 409)
	call(stale, http.MethodPut, providerPath, `{"preset":"provided","model":"personal/model-1","enabled":true}`, 409)
	call(stale, http.MethodPost, writingPath, `{}`, 503)
	if body := call(stale, http.MethodGet, "/api/v2/ai/availability", "", 200); !strings.Contains(body, `"inference":{"knowledge":false,"writing":false`) {
		t.Fatal("stale enabled profile fell back to the platform")
	}
	store.records[42] = foreign
	call(config, http.MethodPost, providerPath+"/test", "", 409)
	call(config, http.MethodPost, writingPath, `{}`, 503)
	store.readErr = errUserProviderUnavailable
	call(stale, http.MethodGet, providerPath, "", 503)
	call(stale, http.MethodPost, writingPath, `{}`, 503)
	store.readErr = nil
	if models.Load() != 1 || writes.Load() != 1 {
		t.Fatal("a stale or wrong-owner credential contacted an upstream")
	}
	reads := store.reads
	if body := call(RefreshConfig{}, http.MethodGet, providerPath, "", 200); !strings.Contains(body, `"setup_available":false`) || !strings.Contains(body, `"config":null`) || store.reads != reads {
		t.Fatal("disabled setup queried or showed the saved row")
	}
	call(RefreshConfig{}, http.MethodDelete, providerPath, "", 200)
	call(RefreshConfig{}, http.MethodDelete, providerPath, "", 200)
	if _, ok := store.records[42]; ok || store.records[43] != foreign {
		t.Fatal("deletion was not idempotent and owner scoped")
	}
	config.AIModelConfig = writingConfig(provider.URL + "/v1")
	call(config, http.MethodPost, writingPath, `{}`, 200)
	if platformWrites.Load() != 1 || store.saved == nil || store.saved.ModelID != "writer" || store.saved.ConfigRevision != 1 {
		t.Fatal("writing did not return to the platform after deletion")
	}
}

func TestUserProviderConnectionRejectsRedirectWithoutForwardingCredential(t *testing.T) {
	var received atomic.Int64
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		received.Add(1)
		fmt.Fprint(w, `{"data":[{"id":"model"}]}`)
	}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/models", http.StatusFound)
	}))
	defer redirect.Close()
	settings := testUserProviderSettings(t, redirect.URL)
	key := "synthetic-api-key"
	record, err := settings.update(42, userProviderInput{Preset: "provided", Model: "model", APIKey: &key}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := testUserProviderConnection(context.Background(), settings, 42, &record); err != errUserProviderUnavailable || received.Load() != 0 {
		t.Fatal(err, received.Load())
	}
}
