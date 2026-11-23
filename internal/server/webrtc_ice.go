package server

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type webRTCCallPolicy struct {
	RingMS           int64  `json:"ring_ms"`
	ActiveMS         int64  `json:"active_ms"`
	TurnTTLSeconds   int64  `json:"turn_ttl_seconds"`
	MaxSDPBytes      int    `json:"max_sdp_bytes"`
	MaxICECandidates int    `json:"max_ice_candidates"`
	MaxICEBytes      int    `json:"max_ice_candidate_bytes"`
	RedisKeyPrefix   string `json:"redis_key_prefix"`
	Environment      struct {
		STUNURLs string `json:"stun_urls"`
		TURNURLs string `json:"turn_urls"`
		Secret   string `json:"turn_shared_secret"`
	}
}

var webRTCCallContract = func() webRTCCallPolicy {
	var contract webRTCCallPolicy
	if json.Unmarshal(contracts.WebRTCCalls, &contract) != nil || contract.RingMS <= 0 || contract.ActiveMS <= 0 ||
		contract.TurnTTLSeconds <= 0 || contract.MaxSDPBytes <= 0 || contract.MaxICECandidates <= 0 || contract.MaxICEBytes <= 0 ||
		contract.RedisKeyPrefix == "" || contract.Environment.STUNURLs == "" || contract.Environment.TURNURLs == "" || contract.Environment.Secret == "" {
		panic("invalid WebRTC contract")
	}
	return contract
}()

type webRTCIceConfig struct {
	stun, turn []string
	secret     string
	invalid    bool
}

func (webRTCIceConfig) String() string   { return "WebRTCIceConfig [redacted]" }
func (webRTCIceConfig) GoString() string { return "WebRTCIceConfig [redacted]" }

type webRTCIceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

type webRTCIceResult struct {
	Servers   []webRTCIceServer `json:"ice_servers"`
	ExpiresAt *time.Time        `json:"expires_at"`
}

func configuredWebRTCIce(get func(string) string) webRTCIceConfig {
	env := webRTCCallContract.Environment
	stun, stunValid := webRTCIceURLs(get(env.STUNURLs), false)
	turn, turnValid := webRTCIceURLs(get(env.TURNURLs), true)
	secret := get(env.Secret)
	return webRTCIceConfig{stun: stun, turn: turn, secret: secret,
		invalid: !stunValid || !turnValid || (len(turn) != 0 && strings.TrimSpace(secret) == "")}
}

var webRTCHostname = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.?$`)

func webRTCIceURLs(raw string, turn bool) ([]string, bool) {
	var urls []string
	for _, rawURL := range strings.Split(raw, ",") {
		address := strings.TrimSpace(rawURL)
		if address == "" || slices.Contains(urls, address) {
			continue
		}
		if len(urls) == 8 {
			return nil, false
		}
		scheme, value, ok := strings.Cut(address, ":")
		if !ok || (turn && scheme != "turn" && scheme != "turns") || (!turn && scheme != "stun" && scheme != "stuns") {
			return nil, false
		}
		host, transport, hasQuery := strings.Cut(value, "?")
		if (hasQuery && (!turn || (transport != "transport=udp" && transport != "transport=tcp"))) ||
			strings.ContainsAny(host, "/\\@#%") || strings.HasSuffix(host, ":") {
			return nil, false
		}
		parsed, err := url.Parse("https://" + host)
		if err != nil || parsed.Host != host || parsed.Hostname() == "" {
			return nil, false
		}
		hostname := parsed.Hostname()
		if strings.HasPrefix(host, "[") {
			if !strings.Contains(hostname, ":") || net.ParseIP(hostname) == nil {
				return nil, false
			}
		} else if !webRTCHostname.MatchString(hostname) || strings.Count(host, ":") > 1 {
			return nil, false
		}
		if port := parsed.Port(); port != "" {
			if number, err := strconv.Atoi(port); err != nil || number < 1 || number > 65535 {
				return nil, false
			}
		}
		urls = append(urls, address)
	}
	return urls, true
}

func (config webRTCIceConfig) credentials(actor int64, now time.Time) webRTCIceResult {
	out := webRTCIceResult{Servers: make([]webRTCIceServer, 0, 2)}
	if len(config.stun) != 0 {
		out.Servers = append(out.Servers, webRTCIceServer{URLs: config.stun})
	}
	if len(config.turn) != 0 {
		expiry := time.Unix(now.Unix()+webRTCCallContract.TurnTTLSeconds, 0).UTC()
		username := strconv.FormatInt(expiry.Unix(), 10) + ":" + strconv.FormatInt(actor, 10)
		mac := hmac.New(sha1.New, []byte(config.secret))
		_, _ = mac.Write([]byte(username))
		out.Servers = append(out.Servers, webRTCIceServer{URLs: config.turn, Username: username,
			Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil))})
		out.ExpiresAt = &expiry
	}
	return out
}

func webRTCIceRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	if r.Method != http.MethodGet || r.URL.EscapedPath() != "/api/v2/calls/ice-servers" {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	if config.webRTCIce.invalid {
		respond(w, 503, 50301, "通话配置暂不可用", nil)
		return true
	}
	respond(w, 200, 200, "success", config.webRTCIce.credentials(actor, config.clock()))
	return true
}
