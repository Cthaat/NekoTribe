package server

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

type visionMissingMedia struct {
	*memorySessions
	lookedUp int64
}

func (s *visionMissingMedia) ownedVisionImage(_ context.Context, _, id int64) (storedVisionImage, error) {
	s.lookedUp = id
	return storedVisionImage{}, sql.ErrNoRows
}

func TestVisionDescribeRejectsURLAndAcceptsSafeMediaID(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		body   string
		status int
		lookup int64
	}{
		{`{"media_id":"https://example.test/picture.png","locale":"en"}`, 400, 0},
		{`{"media_id":9007199254740991,"locale":"en"}`, 404, 9007199254740991},
	} {
		repo := &visionMissingMedia{memorySessions: store()}
		r := httptest.NewRequest(http.MethodPost, "/api/v2/ai/media/describe", strings.NewReader(tc.body))
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{}).ServeHTTP(w, r)
		if w.Code != tc.status || repo.lookedUp != tc.lookup {
			t.Fatal(w.Code, repo.lookedUp, w.Body.String())
		}
	}
}

func TestVisionAdviceIdentityIncludesStoredMediaVersion(t *testing.T) {
	row := storedVisionImage{ID: 9007199254740991, Key: "posts/images/42/example.jpg", Scope: "public", MIME: "image/jpeg", Size: 4}
	ref := row.reference()
	if ref.MediaID != row.ID || !moderationDigestHex(ref.Version) {
		t.Fatal(ref)
	}
	if err := validateModerationImageReferences([]visionImageReference{ref}, []storedVisionImage{row}); err != nil {
		t.Fatal(err)
	}
	row.Size++
	if err := validateModerationImageReferences([]visionImageReference{ref}, []storedVisionImage{row}); !errors.Is(err, errConversationConflict) {
		t.Fatal(err)
	}
}

func testStoredVisionImage(t *testing.T, key, scope string) (LocalStorageConfig, storedVisionImage, string) {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, filepath.FromSlash(key))
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(file, image.NewRGBA(image.Rect(0, 0, 2, 2)), nil); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return LocalStorageConfig{Root: root}, storedVisionImage{ID: 20, Key: key, Scope: scope, MIME: "image/jpeg", Size: int64(len(data))}, "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(data)
}

func visionTestConfig(baseURL string, vision bool) string {
	capabilities := `["tools","structured-output"]`
	if vision {
		capabilities = `["tools","structured-output","vision"]`
	}
	return fmt.Sprintf(`{"schemaVersion":1,"revision":7,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":%q}],"models":[{"id":"reviewer","providerId":"local","model":"test-model","capabilities":%s,"contextWindowTokens":8192,"maxOutputTokens":512}],"bindings":{"knowledge":"reviewer","writing":"reviewer","agent":"reviewer","moderation":"reviewer"}}`, baseURL, capabilities)
}

type visionStoredMediaFixture struct {
	*memorySessions
	row    storedVisionImage
	reads  int
	revoke bool
}

func (s *visionStoredMediaFixture) ownedVisionImage(_ context.Context, actor, id int64) (storedVisionImage, error) {
	s.reads++
	if actor != 42 || id != s.row.ID || (s.revoke && s.reads > 1) {
		return storedVisionImage{}, sql.ErrNoRows
	}
	return s.row, nil
}

type visionQuotaFixture struct {
	calls int
	retry int64
}

func (q *visionQuotaFixture) ReserveAIModelQuota(_ context.Context, actor, cost int64) (int64, error) {
	q.calls++
	if actor != 42 || cost != 1 {
		return 0, errors.New("invalid quota reservation")
	}
	return q.retry, nil
}

type visionProviderRequest struct {
	Messages []struct {
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
	Stream bool `json:"stream"`
}

func TestVisionDescribeOwnedPrivateImageAndQuota(t *testing.T) {
	codec, tokens := fixture(t)
	storage, row, wantURL := testStoredVisionImage(t, "private/post/images/42/example.jpg", "post")
	for _, tc := range []struct {
		name                 string
		revoke               bool
		retry, providerCalls int64
		status               int
	}{
		{"owned private draft", false, 0, 1, 200},
		{"image revoked during inference", true, 0, 1, 404},
		{"quota exhausted", false, 5, 0, 429},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int64
			provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				var sent visionProviderRequest
				if r.URL.Path != "/chat/completions" || json.NewDecoder(r.Body).Decode(&sent) != nil || len(sent.Messages) != 2 || !strings.Contains(string(sent.Messages[1].Content), wantURL) || sent.Stream {
					t.Error("expected authorized image bytes in the final user message")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				fmt.Fprintf(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":%q}}]}`, `{"alt_text":" 一张黑色方形图片 ","tags":["#图片","图片","写真"]}`)
			}))
			defer provider.Close()
			repo := &visionStoredMediaFixture{memorySessions: store(), row: row, revoke: tc.revoke}
			quota := &visionQuotaFixture{retry: tc.retry}
			r := httptest.NewRequest(http.MethodPost, "/api/v2/ai/media/describe", strings.NewReader(`{"media_id":20,"locale":"zh"}`))
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			handler := NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{
				LocalStorage: storage, AIModelQuotaLimiter: quota, AIModelConfig: visionTestConfig(provider.URL, true),
				metricsToken: testMetricsToken,
			})
			handler.ServeHTTP(w, r)
			if w.Code != tc.status || calls.Load() != tc.providerCalls || quota.calls != 1 {
				t.Fatal(w.Code, calls.Load(), quota.calls, w.Body.String())
			}
			if tc.status == 200 && !strings.Contains(w.Body.String(), `"alt_text":"一张黑色方形图片","tags":["图片","写真"]`) {
				t.Fatal(w.Body.String())
			}
			if tc.status == 429 && w.Header().Get("Retry-After") != "5" {
				t.Fatal(w.Header())
			}
			result, rejections := "failure", 0
			if tc.status == 200 {
				result = "success"
			}
			if tc.status == 429 {
				rejections = 1
			}
			requireMetricLines(t, testScrape(handler, "Bearer "+testMetricsToken).Body.String(),
				fmt.Sprintf(`nekotribe_ai_requests_total{operation="image_description",result=%q} 1`, result),
				fmt.Sprintf(`nekotribe_ai_quota_rejections_total{operation="image_description"} %d`, rejections))
		})
	}
}

type draftMediaAltFixture struct {
	*memorySessions
	oracle OracleSessions
}

func (s *draftMediaAltFixture) updateDraftMediaAltText(ctx context.Context, actor, id int64, alt *string) error {
	return s.oracle.updateDraftMediaAltText(ctx, actor, id, alt)
}

func TestVisionPatchAltTextChecksAttachmentUnderLock(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		mode                    string
		status, commits, writes int
	}{
		{"success", 200, 1, 1},
		{"in-use", 409, 0, 0},
		{"missing", 404, 0, 0},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			state := &mediaDeleteDBState{mode: tc.mode}
			db := sql.OpenDB(mediaDeleteConnector{state})
			defer db.Close()
			repo := &draftMediaAltFixture{memorySessions: store(), oracle: OracleSessions{db}}
			r := httptest.NewRequest(http.MethodPatch, "/api/v2/media/20", strings.NewReader(`{"alt_text":""}`))
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			NewHandler(codec, repo, CorsPolicy{}).ServeHTTP(w, r)
			if w.Code != tc.status || state.commits != tc.commits || len(state.writes) != tc.writes || len(state.reads) == 0 || state.reads[0].sql != visionContract.SQL["lock_owned_image"] {
				t.Fatal(w.Code, state.commits, state.reads, state.writes, w.Body.String())
			}
			if tc.status == 200 {
				if len(state.reads) != 2 || state.reads[1].sql != visionContract.SQL["image_is_attached"] || !strings.Contains(w.Body.String(), `"alt_text":null`) {
					t.Fatal(state.reads, w.Body.String())
				}
				for _, arg := range state.writes[0].args {
					if arg.Name == "alt_text" && arg.Value != nil {
						t.Fatal("expected cleared alt text to use SQL NULL")
					}
				}
			}
		})
	}
}

func TestVisionModerationImageOnlyAndTextOnly(t *testing.T) {
	codec, tokens := fixture(t)
	storage, row, wantURL := testStoredVisionImage(t, "posts/images/42/example.jpg", "public")
	for _, tc := range []struct {
		name               string
		vision, changed    bool
		status, preflights int
		calls              int64
	}{
		{"image only", true, false, 200, 1, 1},
		{"text only", false, false, 200, 0, 1},
		{"image changed before inference", true, true, 409, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int64
			provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				var sent visionProviderRequest
				if json.NewDecoder(r.Body).Decode(&sent) != nil || len(sent.Messages) != 2 || strings.Contains(string(sent.Messages[1].Content), wantURL) != tc.vision || sent.Stream {
					t.Error("unexpected image or streaming mode")
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				fmt.Fprintf(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":%q}}]}`, `{"risk":"none","reason":"可见资料","recommendation":"no_action","rule_ids":[3]}`)
			}))
			defer provider.Close()
			repo := &moderationFixtureStore{text: "test", images: []storedVisionImage{row}}
			if tc.vision {
				repo.text = ""
			}
			if tc.changed {
				repo.condition = "image_changed"
			}
			r := httptest.NewRequest(http.MethodPost, "/api/v2/ai/conversations/e7dd4d7f-8462-45b6-9bf4-a630d0ba7478/moderation-generate", strings.NewReader(`{"target_type":"post","target_id":20,"locale":"zh","expected_sequence":0}`))
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			if tc.vision {
				r.Header.Set("Accept", "text/event-stream")
			}
			w := httptest.NewRecorder()
			config := RefreshConfig{LocalStorage: storage, AIModelQuotaLimiter: singleCallAIQuota{}, AIModelConfig: visionTestConfig(provider.URL, tc.vision)}
			if !aiConversationRoute(w, r, codec, repo, config) || w.Code != tc.status || repo.vision != tc.vision || calls.Load() != tc.calls || repo.visionPreflights != tc.preflights || (repo.written != nil) != (tc.status == 200) {
				t.Fatal(w.Code, repo.vision, repo.visionPreflights, calls.Load(), w.Body.String())
			}
			if tc.changed {
				return
			}
			written := repo.written.ModerationAdvice
			if tc.vision {
				if written.Version != 2 || len(written.ImageSources) != 1 || written.ImageSources[0] != row.reference() || !strings.Contains(w.Body.String(), "event: done") || strings.Contains(w.Body.String(), "event: delta") {
					t.Fatal(written, w.Body.String())
				}
			} else if written.Version != 1 || len(written.ImageSources) != 0 {
				t.Fatal(written)
			}
		})
	}
}
