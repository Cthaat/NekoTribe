package server

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestSharedStoragePublicURLs(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/storage-public-urls.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ID    string `json:"id"`
		Cases []struct {
			ID       string            `json:"id"`
			Env      map[string]string `json:"env"`
			Input    *string           `json:"input"`
			Expected string            `json:"expected"`
			Error    bool              `json:"error"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.ID != "STORAGE-PUBLIC-URLS" || len(fixture.Cases) != 26 {
		t.Fatal("unexpected fixture")
	}
	for _, c := range fixture.Cases {
		t.Run(c.ID, func(t *testing.T) {
			lookup := func(key string) (string, bool) { value, ok := c.Env[key]; return value, ok }
			config := storageURLConfig(lookup)
			input := ""
			if c.Input != nil {
				input = *c.Input
			}
			got, err := normalizeAvatarURL(config, input)
			if (err != nil) != c.Error {
				t.Fatalf("error=%v expected error=%v", err, c.Error)
			}
			if err == nil && got != c.Expected {
				t.Fatalf("got %q, want %q", got, c.Expected)
			}
		})
	}
}

func TestLoginUsesConfiguredPublicAvatarURL(t *testing.T) {
	store, _, codec := newLoginFixture(t)
	store.avatar = "/uploads/avatars/cat.png"
	config := RefreshConfig{AccessSeconds: 900, RefreshSeconds: 3600, clock: func() time.Time { return time.Unix(1700000000, 0) }, Storage: storageURLConfig(func(key string) (string, bool) {
		values := map[string]string{"STORAGE_PUBLIC_BASE": "/media", "STORAGE_CDN_BASE_URL": "https://cdn.example"}
		value, ok := values[key]
		return value, ok
	})}
	response := loginRequest(NewHandlerWithConfig(codec, store, CorsPolicy{}, config), `{"account":"tester","password":"synthetic-password"}`)
	if response.Code != 200 {
		t.Fatalf("login failed: %d", response.Code)
	}
	var body struct {
		Data struct {
			User struct {
				AvatarURL string `json:"avatar_url"`
			} `json:"user"`
		} `json:"data"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Data.User.AvatarURL != "https://cdn.example/media/avatars/cat.png" {
		t.Fatalf("avatar=%q", body.Data.User.AvatarURL)
	}
}

func TestLoginWithUnsafeStorageConfigDoesNotExposeCredentialsOrSetCookies(t *testing.T) {
	store, _, codec := newLoginFixture(t)
	config := RefreshConfig{AccessSeconds: 900, RefreshSeconds: 3600, clock: func() time.Time { return time.Unix(1700000000, 0) }, Storage: storageURLConfig(func(key string) (string, bool) {
		if key == "BASE_URL" {
			return "https://user:synthetic-password@host.example", true
		}
		return "", false
	})}
	response := loginRequest(NewHandlerWithConfig(codec, store, CorsPolicy{}, config), `{"account":"tester","password":"synthetic-password"}`)
	if response.Code != 500 || len(response.Result().Cookies()) != 0 || strings.Contains(response.Body.String(), "synthetic-password") {
		t.Fatal("unsafe storage configuration was exposed")
	}
}
