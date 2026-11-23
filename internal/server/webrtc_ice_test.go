package server

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestWebRTCIceCredentialsRequireSessionAndRemainPrivate(t *testing.T) {
	codec, tokens := fixture(t)
	now := time.Unix(1700000000, 0)
	const secret = "synthetic-turn-secret"
	for _, tc := range []struct {
		name, stun, turn, secret, token string
		want                            int
	}{
		{"anonymous", "", "", "", "", 401},
		{"empty", "", "", "", tokens["access-hs256"], 200},
		{"turn", "stun:stun.example.test:3478", "turns:turn.example.test:5349?transport=tcp", secret, tokens["access-hs256"], 200},
		{"missing secret", "", "turn:turn.example.test:3478", "", tokens["access-hs256"], 503},
		{"invalid URL", "", "turn:secret@turn.example.test", secret, tokens["access-hs256"], 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := validEnv()
			env["WEBRTC_STUN_URLS"], env["WEBRTC_TURN_URLS"], env["WEBRTC_TURN_SHARED_SECRET"] = tc.stun, tc.turn, tc.secret
			config, err := LoadConfig(func(key string) (string, bool) { value, ok := env[key]; return value, ok })
			if err != nil {
				t.Fatal(err)
			}
			config.Refresh.clock = func() time.Time { return now }
			req := httptest.NewRequest(http.MethodGet, "/api/v2/calls/ice-servers", nil)
			if tc.token != "" {
				req.Header.Set("Authorization", "Bearer "+tc.token)
			}
			out := httptest.NewRecorder()
			NewHandlerWithConfig(codec, store(), CorsPolicy{}, config.Refresh).ServeHTTP(out, req)
			if out.Code != tc.want || out.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(out.Body.String(), secret) {
				t.Fatalf("ICE status=%d cache=%q", out.Code, out.Header().Get("Cache-Control"))
			}
			if tc.want != 200 {
				return
			}
			var response struct {
				Data struct {
					Servers []struct {
						URLs                 []string `json:"urls"`
						Username, Credential string
					} `json:"ice_servers"`
					Expires *time.Time `json:"expires_at"`
				}
			}
			if json.Unmarshal(out.Body.Bytes(), &response) != nil {
				t.Fatal("invalid ICE response")
			}
			if tc.turn == "" {
				if response.Data.Servers == nil || len(response.Data.Servers) != 0 || response.Data.Expires != nil {
					t.Fatal("invalid empty ICE response")
				}
				return
			}
			expiry := now.Add(14700 * time.Second)
			username := strconv.FormatInt(expiry.Unix(), 10) + ":42"
			mac := hmac.New(sha1.New, []byte(secret))
			mac.Write([]byte(username))
			if len(response.Data.Servers) != 2 || response.Data.Expires == nil || !response.Data.Expires.Equal(expiry) ||
				len(response.Data.Servers[0].URLs) != 1 || response.Data.Servers[0].URLs[0] != tc.stun ||
				len(response.Data.Servers[1].URLs) != 1 || response.Data.Servers[1].URLs[0] != tc.turn ||
				response.Data.Servers[1].Username != username || response.Data.Servers[1].Credential != base64.StdEncoding.EncodeToString(mac.Sum(nil)) {
				t.Fatal("invalid scoped TURN credentials")
			}
		})
	}
}
