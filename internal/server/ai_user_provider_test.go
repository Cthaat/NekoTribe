package server

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

func testUserProviderSettings(t *testing.T, endpoint string) userProviderSettings {
	t.Helper()
	values := map[string]string{"AI_USER_PROVIDER_SECRET_B64": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{17}, 32)), "AI_USER_PROVIDER_URL": endpoint}
	return configuredUserProvider(func(key string) string { return values[key] })
}

func TestUserProviderSharedCipherVector(t *testing.T) {
	var spec struct {
		Vector struct {
			Owner   int64  `json:"owner_id"`
			Preset  string `json:"preset"`
			BaseURL string `json:"base_url"`
			Master  string `json:"fixture_master_b64"`
			Key     string `json:"fixture_key"`
			Box     string `json:"fixture_box"`
		} `json:"crypto_vector"`
	}
	if json.Unmarshal(contracts.AIUserProvider, &spec) != nil || spec.Vector.Owner == 0 || spec.Vector.Key == "" || spec.Vector.Box == "" {
		t.Fatal("missing shared synthetic vector")
	}
	vector := spec.Vector
	setup := func(endpoint string) userProviderSettings {
		values := map[string]string{"AI_USER_PROVIDER_SECRET_B64": vector.Master, "AI_USER_PROVIDER_URL": endpoint}
		return configuredUserProvider(func(key string) string { return values[key] })
	}
	settings := setup(vector.BaseURL)
	record := userProviderRecord{Preset: vector.Preset, BaseURL: vector.BaseURL, SecretBox: vector.Box}
	if key, err := settings.open(vector.Owner, &record); err != nil || key != vector.Key {
		t.Fatal("shared ciphertext could not be opened", err)
	}
	if _, err := settings.open(vector.Owner+1, &record); !errors.Is(err, errUserProviderReconnect) {
		t.Fatal("shared ciphertext opened under a different owner", err)
	}
	record.BaseURL = "https://Different.example.test:443/v1"
	if _, err := setup(record.BaseURL).open(vector.Owner, &record); !errors.Is(err, errUserProviderReconnect) {
		t.Fatal("shared ciphertext opened under a different endpoint", err)
	}
}

func TestUserProviderCiphertextBindsOwnerPresetAndSavedURL(t *testing.T) {
	settings := testUserProviderSettings(t, " https://Personal.Example.test:443/v1/// ")
	key := "synthetic-personal-api-key"
	record, err := settings.update(42, userProviderInput{Preset: "provided", Model: "lab/model", Enabled: true, APIKey: &key}, nil)
	if err != nil || strings.Contains(record.SecretBox, key) || record.BaseURL != "https://Personal.Example.test:443/v1" || record.Revision != 1 {
		t.Fatal("storage receipt is incorrect", err)
	}
	box, err := base64.RawURLEncoding.DecodeString(record.SecretBox)
	block, _ := aes.NewCipher(bytes.Repeat([]byte{17}, 32))
	aead, _ := cipher.NewGCM(block)
	if err != nil || len(box) != 12+len(key)+16 {
		t.Fatal("invalid interoperable envelope", err)
	}
	opened, err := aead.Open(nil, box[:12], box[12:], []byte("nekotribe.ai-provider.v1\n42\nprovided\nhttps://Personal.Example.test:443/v1"))
	if err != nil || string(opened) != key {
		t.Fatal("shared AEAD format did not round-trip", err)
	}
	if _, err := settings.open(43, &record); !errors.Is(err, errUserProviderReconnect) {
		t.Fatal("another owner decrypted the key", err)
	}
	changed := testUserProviderSettings(t, "https://other.example.test/v1")
	if _, err := changed.open(42, &record); !errors.Is(err, errUserProviderReconnect) {
		t.Fatal("stale endpoint decrypted the key", err)
	}
	if _, err := changed.update(42, userProviderInput{Preset: "provided", Model: "lab/model", Enabled: true}, &record); !errors.Is(err, errUserProviderReconnect) {
		t.Fatal("stale endpoint retained the original key", err)
	}
	aliases := testUserProviderSettings(t, userProviderContract.DefaultBaseURL)
	provided, err := aliases.update(42, userProviderInput{Preset: "provided", Model: "lab/model", APIKey: &key}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := aliases.update(42, userProviderInput{Preset: "default", Model: "lab/model"}, &provided); !errors.Is(err, errUserProviderReconnect) {
		t.Fatal("different preset retained the original key at the same URL", err)
	}
}

func TestUserProviderInputRejectsInjectedURLAndBadKey(t *testing.T) {
	for _, raw := range []string{
		`{"preset":"default","model":"gpt-4o","enabled":true,"base_url":"https://example.test/"}`,
		`{"preset":"provided","model":"bad model","enabled":true}`,
		`{"preset":"default","model":"gpt-4o","enabled":true,"api_key":"bad\r\nsecret"}`,
		`{"preset":"default","model":"gpt-4o","enabled":true,"api_key":null}`,
	} {
		if _, err := parseUserProviderInput([]byte(raw)); !errors.Is(err, errUserProviderInvalid) {
			t.Fatal("invalid input was accepted", err)
		}
	}
}
