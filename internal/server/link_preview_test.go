package server

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestLinkPreviewRouteRequiresAccess(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/api/v2/links/preview?url=https%3A%2F%2Fexample.com", nil)
	response := httptest.NewRecorder()
	NewHandler(nil, nil, CorsPolicy{}).ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || response.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("preview returned %d %s", response.Code, response.Body)
	}
}

var previewTestPublicIP = netip.MustParseAddr("93.184.216.34")

type previewWireRequest struct {
	address, host, path string
	headers             http.Header
}

type previewMemoryWire struct {
	mu        sync.Mutex
	responses []string
	requests  chan previewWireRequest
	dials     int
}

func (w *previewMemoryWire) dial(ctx context.Context, network, address string) (net.Conn, error) {
	w.mu.Lock()
	next := w.dials
	w.dials++
	w.mu.Unlock()
	if next >= len(w.responses) || network != "tcp" {
		return nil, errors.New("unexpected isolated dial")
	}
	server, client := net.Pipe()
	deadline, _ := ctx.Deadline()
	_ = server.SetDeadline(deadline)
	go func() {
		defer server.Close()
		req, err := http.ReadRequest(bufio.NewReader(server))
		if err == nil {
			w.requests <- previewWireRequest{address, req.Host, req.RequestURI, req.Header}
			_, _ = io.WriteString(server, w.responses[next])
		}
	}()
	return client, nil
}

func makePreviewWire(responses ...string) *previewMemoryWire {
	return &previewMemoryWire{responses: responses, requests: make(chan previewWireRequest, len(responses))}
}

func previewHTTPReply(contentType, body string) string {
	return fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n%s", contentType, len(body), body)
}

func previewRedirect(status int, target string) string {
	return fmt.Sprintf("HTTP/1.1 %d Redirect\r\nLocation: %s\r\nContent-Length: 0\r\n\r\n", status, target)
}

type previewFixtureCache struct {
	raw, key string
	sets     int
	ttl      time.Duration
	readErr  error
}

func (c *previewFixtureCache) get(ctx context.Context, key string) (string, error) {
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > time.Duration(previewPolicy.CacheTimeoutMS)*time.Millisecond {
		return "", errors.New("missing cache read budget")
	}
	if c.readErr != nil {
		return "", c.readErr
	}
	if c.key == key {
		return c.raw, nil
	}
	return "", nil
}

func (c *previewFixtureCache) set(ctx context.Context, key, raw string, ttl time.Duration) error {
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > time.Duration(previewPolicy.CacheTimeoutMS)*time.Millisecond {
		return errors.New("missing cache write budget")
	}
	c.key, c.raw, c.ttl = key, raw, ttl
	c.sets++
	return nil
}

func TestLinkPreviewPublicPagePinnedHTTPAndPositiveCache(t *testing.T) {
	codec, tokens := fixture(t)
	wire := makePreviewWire(previewHTTPReply("text/html; charset=utf-8", `<!doctype html><title>fallback</title>
		<meta name="description" content="fallback"><!-- <meta property="og:title" content="ignored"> -->
		<meta property="og:title" content=" A &amp;  B ">
		<meta property="og:description" content="original description">
		<meta property="og:site_name" content="Example site">
		<meta property="og:url" content="http://localhost:4000">
		<img src="http://localhost/raster.png">`))
	cache := &previewFixtureCache{readErr: errors.New("cache temporarily unavailable")}
	var lookups []string
	svc := &linkPreviewService{cache: cache, dial: wire.dial, lookup: func(_ context.Context, network, host string) ([]netip.Addr, error) {
		if network != "ip" {
			t.Fatalf("incorrect address family check: %s", network)
		}
		lookups = append(lookups, host)
		return []netip.Addr{previewTestPublicIP}, nil
	}}
	h := NewHandlerWithConfig(codec, store(), CorsPolicy{}, RefreshConfig{linkPreview: svc})
	request := func(target string) string {
		t.Helper()
		r := httptest.NewRequest(http.MethodGet, "/api/v2/links/preview?url="+url.QueryEscape(target), nil)
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		r.AddCookie(&http.Cookie{Name: "unrelated", Value: "local-session"})
		res := httptest.NewRecorder()
		h.ServeHTTP(res, r)
		if res.Code != http.StatusOK || res.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("unexpected preview response %d %s", res.Code, res.Body)
		}
		return res.Body.String()
	}
	body := request("HTTP://Example.COM:80/a?keep=1#omit")
	got := <-wire.requests
	if got.address != "93.184.216.34:80" || got.host != "example.com" || got.path != "/a?keep=1" ||
		got.headers.Get("Accept-Encoding") != "identity" || got.headers.Get("Accept") != "text/html, application/xhtml+xml" ||
		got.headers.Get("Authorization") != "" || got.headers.Get("Cookie") != "" || got.headers.Get("Referer") != "" {
		t.Fatalf("incorrect isolated outbound request %+v", got)
	}
	if !strings.Contains(body, `"url":"http://example.com/a?keep=1","title":"A \u0026 B","description":"original description","site_name":"Example site"`) {
		t.Fatalf("wrong preview %s", body)
	}
	digest := sha256.Sum256([]byte("http://example.com/a?keep=1"))
	if !slices.Equal(lookups, []string{"example.com."}) || cache.sets != 1 ||
		cache.key != previewPolicy.CachePrefix+hex.EncodeToString(digest[:]) || cache.ttl != time.Hour {
		t.Fatalf("wrong DNS/cache behavior, lookups %v, cache %+v", lookups, cache)
	}
	cache.readErr = nil
	if cached := request("http://example.com/a?keep=1#another"); cached != body || cache.sets != 1 || len(lookups) != 1 {
		t.Fatalf("positive cache was not reused: %s", cached)
	}
}

func TestLinkPreviewDeniesInvalidTargetsAndEveryAddressBeforeDial(t *testing.T) {
	for _, raw := range []string{
		"file:///example.com", "//example.com", "http:example.com", "http://u:p@example.com",
		"https://example.com:80", "http://example.com:443", "https://example.com:0443",
		"http://127.0.0.1", "http://127.1", "http://0x7f000001", "http://2130706433", "http://[::ffff:8.8.8.8]",
		"http://169.254.169.254", "http://168.63.129.16", "http://100.100.100.200",
		"http://[64:ff9b::0808:0808]", "http://[2001:db8::1]", "http://[2002:0808:0808::]", "http://[3fff::1]",
		"http://[2600::1%25iface]", "https://metadata.google.internal", "https://foo.localhost.",
		"http://example.com\\other", "http://example.com/p q", "http://example.com/\x7f",
		"http://example.com/" + strings.Repeat("a", previewPolicy.MaxURLBytes),
	} {
		if _, err := validatedLinkPreviewURL(raw, nil); !errors.Is(err, errLinkPreviewBlocked) {
			t.Errorf("accepted blocked URL input shape %q", raw)
		}
	}
	for _, raw := range []string{"http://8.8.8.8:80", "https://[2606:4700::1111]:443", "https://例子.example"} {
		if _, err := validatedLinkPreviewURL(raw, nil); err != nil {
			t.Errorf("rejected public URL shape %q", raw)
		}
	}
	for _, blocked := range previewBlockedRanges {
		if previewPublicIP(blocked.Addr()) {
			t.Errorf("accepted blocked range %s", blocked)
		}
	}
	wire := makePreviewWire(previewRedirect(302, "//next.example/path"))
	svc := &linkPreviewService{dial: wire.dial, lookup: func(_ context.Context, _, host string) ([]netip.Addr, error) {
		if host == "next.example." {
			return []netip.Addr{previewTestPublicIP, netip.MustParseAddr("10.0.0.20")}, nil
		}
		return []netip.Addr{previewTestPublicIP}, nil
	}}
	codec, tokens := fixture(t)
	request := httptest.NewRequest(http.MethodGet, "/api/v2/links/preview?url="+url.QueryEscape("http://first.example"), nil)
	request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	resp := httptest.NewRecorder()
	NewHandlerWithConfig(codec, store(), CorsPolicy{}, RefreshConfig{linkPreview: svc}).ServeHTTP(resp, request)
	if resp.Code != http.StatusBadRequest || wire.dials != 1 || strings.Contains(resp.Body.String(), "next.example") {
		t.Fatalf("blocked redirect returned %d %s after %d dials", resp.Code, resp.Body, wire.dials)
	}
}

func TestLinkPreviewRejectsReservedHostsBeforeDNS(t *testing.T) {
	svc := &linkPreviewService{lookup: func(context.Context, string, string) ([]netip.Addr, error) {
		t.Error("reserved host reached DNS")
		return nil, nil
	}}
	for _, host := range []string{"localhost", "router.local", "api.internal", "device.home.arpa.", "Onion", "private.ONION."} {
		if _, err := svc.preview(context.Background(), "https://"+host); !errors.Is(err, errLinkPreviewBlocked) {
			t.Errorf("reserved host %q returned %v", host, err)
		}
	}
	for _, host := range []string{"onion.example.com", "example-onion.com", "notonion"} {
		if !validPreviewDNSName(host) {
			t.Errorf("public hostname shape %q rejected", host)
		}
	}
}

func TestLinkPreviewRedirectAndBodyBounds(t *testing.T) {
	wire := makePreviewWire(
		previewRedirect(301, "/two"), previewRedirect(303, "http://b.example/three"),
		previewRedirect(307, "/four"), previewRedirect(308, "/five"),
	)
	var deadlines []time.Time
	svc := &linkPreviewService{dial: wire.dial, lookup: func(ctx context.Context, _, _ string) ([]netip.Addr, error) {
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > 3*time.Second {
			t.Fatal("missing DNS deadline")
		}
		deadlines = append(deadlines, deadline)
		return []netip.Addr{previewTestPublicIP}, nil
	}}
	result, err := svc.preview(context.Background(), "http://a.example/one")
	if err != nil || result != nil || len(deadlines) != 4 || wire.dials != 4 {
		t.Fatalf("invalid bounded redirect result %+v, error %v, DNS %d, dials %d", result, err, len(deadlines), wire.dials)
	}
	for _, deadline := range deadlines {
		if !deadline.Equal(deadlines[0]) {
			t.Fatal("redirect restarted the chain deadline")
		}
	}
	large := "<title>Valid title</title>" + strings.Repeat("a", previewPolicy.MaxBodyBytes)
	for _, tc := range []struct{ name, response string }{
		{"declared oversize", previewHTTPReply("text/html", large)},
		{"streamed oversize", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n" + large},
		{"wrong media type", previewHTTPReply("text/plain", "<title>no</title>")},
		{"compressed", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\nContent-Length: 17\r\n\r\n<title>no</title>"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			wire := makePreviewWire(tc.response)
			svc := &linkPreviewService{dial: wire.dial, cache: &previewFixtureCache{}}
			result, err := svc.preview(context.Background(), "http://93.184.216.34")
			if err != nil || result != nil || svc.cache.(*previewFixtureCache).sets != 0 {
				t.Fatalf("accepted unsupported body %+v, error %v", result, err)
			}
		})
	}
}

func TestLinkPreviewTLSUsesOriginalNameAndRejectsUntrustedCert(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	certificate := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"tls.example"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, public, private)
	if err != nil {
		t.Fatal(err)
	}
	serverName := make(chan string, 1)
	pinnedAddress := make(chan string, 1)
	svc := &linkPreviewService{
		lookup: func(context.Context, string, string) ([]netip.Addr, error) {
			return []netip.Addr{previewTestPublicIP}, nil
		},
		dial: func(ctx context.Context, _, address string) (net.Conn, error) {
			pinnedAddress <- address
			server, client := net.Pipe()
			go func() {
				defer server.Close()
				cfg := &tls.Config{
					Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: private}},
					GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
						serverName <- hello.ServerName
						return nil, nil
					},
				}
				secure := tls.Server(server, cfg)
				if secure.HandshakeContext(ctx) == nil {
					_, _ = io.WriteString(secure, previewHTTPReply("text/html", "<title>Should fail verification</title>"))
				}
			}()
			return client, nil
		},
	}
	result, err := svc.preview(context.Background(), "https://tls.example")
	if result != nil || err != nil {
		t.Fatalf("accepted untrusted certificate: %+v, error %v", result, err)
	}
	if len(serverName) != 1 || len(pinnedAddress) != 1 || <-serverName != "tls.example" || <-pinnedAddress != "93.184.216.34:443" {
		t.Fatal("TLS did not use the original hostname over the checked IP")
	}
}
