package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCORSActualRequestsIgnorePreflightOnlyHeaders(t *testing.T) {
	codec, tokens := fixture(t)
	s := store()
	ts := httptest.NewServer(NewHandler(codec, s, CorsPolicy{Origins: []string{"https://app.example"}}))
	defer ts.Close()
	r, _ := http.NewRequest("DELETE", ts.URL+"/api/v2/auth/sessions/peer", nil)
	r.Header.Set("Origin", "https://app.example")
	r.Header.Set("Authorization", tokens["access-hs256"])
	r.Header.Set("Access-Control-Request-Method", "TRACE")
	r.Header.Set("Access-Control-Request-Headers", "x-disallowed")
	resp, e := ts.Client().Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Access-Control-Allow-Origin") != "https://app.example" {
		t.Fatalf("actual request lost CORS: %d %v", resp.StatusCode, resp.Header)
	}
}
func TestCORSRejectsNonSerializedOrigins(t *testing.T) {
	for _, origin := range []string{"https://app.example?", "https://app.example#", "http://localhost:", "http://localhost:65536", "http://localhost:08080"} {
		if normalizeOrigin(origin) != "" {
			t.Errorf("accepted nonserialized origin %s", origin)
		}
	}
}
func TestCORSExplicitEmptyPrefixOverridesFallback(t *testing.T) {
	env := validEnv()
	env["NUXT_CORS_ALLOW_LOCALHOST_ORIGINS"] = ""
	env["CORS_ALLOW_LOCALHOST_ORIGINS"] = "true"
	env["NODE_ENV"] = "development"
	c, e := LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if e != nil {
		t.Fatal(e)
	}
	if c.Cors.Localhost {
		t.Fatal("empty prefixed setting must override fallback")
	}
}
