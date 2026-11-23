package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/redis/go-redis/v9"
	"golang.org/x/net/idna"
)

type linkPreviewPolicy struct {
	MaxURLBytes      int      `json:"max_url_bytes"`
	TimeoutMS        int      `json:"timeout_ms"`
	MaxRedirects     int      `json:"max_redirects"`
	MaxBodyBytes     int      `json:"max_body_bytes"`
	CacheTimeoutMS   int      `json:"cache_timeout_ms"`
	CacheTTLSeconds  int      `json:"cache_ttl_seconds"`
	CachePrefix      string   `json:"cache_prefix"`
	TitleChars       int      `json:"title_chars"`
	DescriptionChars int      `json:"description_chars"`
	SiteNameChars    int      `json:"site_name_chars"`
	IPv6Prefix       string   `json:"ipv6_public_prefix"`
	BlockedCIDRs     []string `json:"blocked_cidrs"`
	BlockedHosts     []string `json:"blocked_host_suffixes"`
}

var previewPolicy = func() linkPreviewPolicy {
	var policy linkPreviewPolicy
	if json.Unmarshal(contracts.LinkPreview, &policy) != nil || policy.MaxURLBytes < 1 ||
		policy.TimeoutMS < 1 || policy.MaxBodyBytes < 1 || policy.MaxRedirects < 0 ||
		policy.CacheTimeoutMS < 1 || policy.CacheTTLSeconds < 1 || policy.CachePrefix == "" ||
		policy.TitleChars < 1 || policy.DescriptionChars < 1 || policy.SiteNameChars < 1 ||
		len(policy.BlockedCIDRs) == 0 || len(policy.BlockedHosts) == 0 {
		panic("invalid link preview contract")
	}
	return policy
}()

var (
	errLinkPreviewBlocked = errors.New("link preview URL invalid or blocked")
	previewIPv6Prefix     = netip.MustParsePrefix(previewPolicy.IPv6Prefix)
	previewDNSLabel       = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
	previewNumericLabel   = regexp.MustCompile(`^(?:[0-9]+|0x[0-9a-f]*)$`)
	previewBlockedRanges  = func() []netip.Prefix {
		ranges := make([]netip.Prefix, 0, len(previewPolicy.BlockedCIDRs))
		for _, raw := range previewPolicy.BlockedCIDRs {
			ranges = append(ranges, netip.MustParsePrefix(raw))
		}
		return ranges
	}()
)

type linkPreviewResult struct {
	URL         string `json:"url"`
	Title       string `json:"title"`
	Description string `json:"description"`
	SiteName    string `json:"site_name"`
}

type linkPreviewCache interface {
	get(context.Context, string) (string, error)
	set(context.Context, string, string, time.Duration) error
}

type linkPreviewService struct {
	lookup func(context.Context, string, string) ([]netip.Addr, error)
	dial   func(context.Context, string, string) (net.Conn, error)
	cache  linkPreviewCache
}

type linkPreviewRedis struct{ client *redis.Client }

func (c linkPreviewRedis) get(ctx context.Context, key string) (string, error) {
	return c.client.Get(ctx, key).Result()
}

func (c linkPreviewRedis) set(ctx context.Context, key, value string, ttl time.Duration) error {
	return c.client.Set(ctx, key, value, ttl).Err()
}

func newLinkPreviewService(publisher NotificationEventPublisher) *linkPreviewService {
	dialer := &net.Dialer{}
	svc := &linkPreviewService{lookup: net.DefaultResolver.LookupNetIP, dial: dialer.DialContext}
	if p, ok := publisher.(*UserEventPublisher); ok && p != nil {
		if client, ok := p.client.(*redis.Client); ok {
			svc.cache = linkPreviewRedis{client}
		}
	}
	return svc
}

func previewPublicIP(ip netip.Addr) bool {
	if !ip.IsValid() || ip.Zone() != "" || ip.Is4In6() || !ip.IsGlobalUnicast() ||
		ip.Is6() && !previewIPv6Prefix.Contains(ip) {
		return false
	}
	for _, blocked := range previewBlockedRanges {
		if blocked.Contains(ip) {
			return false
		}
	}
	return true
}

func previewDefaultPort(scheme string) string {
	if scheme == "https" {
		return "443"
	}
	return "80"
}

func validatedLinkPreviewURL(raw string, base *url.URL) (*url.URL, error) {
	if raw == "" || len(raw) > previewPolicy.MaxURLBytes || !utf8.ValidString(raw) ||
		strings.IndexFunc(raw, func(r rune) bool { return r <= 0x20 || r == 0x7f || r == '\\' }) != -1 {
		return nil, errLinkPreviewBlocked
	}
	target, err := url.Parse(raw)
	if err != nil {
		return nil, errLinkPreviewBlocked
	}
	if base != nil {
		target = base.ResolveReference(target)
	} else {
		target = (&url.URL{}).ResolveReference(target)
	}
	target.Scheme = strings.ToLower(target.Scheme)
	if (target.Scheme != "http" && target.Scheme != "https") || target.Host == "" || target.User != nil ||
		target.Opaque != "" || strings.HasSuffix(target.Host, ":") ||
		(target.Port() != "" && target.Port() != previewDefaultPort(target.Scheme)) {
		return nil, errLinkPreviewBlocked
	}
	host := target.Hostname()
	if ip, err := netip.ParseAddr(host); err == nil {
		if !previewPublicIP(ip) {
			return nil, errLinkPreviewBlocked
		}
		host = ip.String()
		if ip.Is6() {
			host = "[" + host + "]"
		}
	} else {
		if strings.ContainsAny(target.Host, "[]%") {
			return nil, errLinkPreviewBlocked
		}
		ascii, err := idna.Lookup.ToASCII(host)
		if err != nil || !validPreviewDNSName(ascii) {
			return nil, errLinkPreviewBlocked
		}
		host = strings.ToLower(ascii)
	}
	target.Host = host
	target.Fragment, target.RawFragment = "", ""
	if target.Path == "" {
		target.Path = "/"
	}
	if len(target.String()) > previewPolicy.MaxURLBytes {
		return nil, errLinkPreviewBlocked
	}
	return target, nil
}

func validPreviewDNSName(host string) bool {
	name := strings.TrimSuffix(strings.ToLower(host), ".")
	if name == "" || len(name) > 253 {
		return false
	}
	labels := strings.Split(name, ".")
	if previewNumericLabel.MatchString(labels[len(labels)-1]) {
		return false
	}
	for _, suffix := range previewPolicy.BlockedHosts {
		if name == suffix || strings.HasSuffix(name, "."+suffix) {
			return false
		}
	}
	for _, label := range labels {
		if !previewDNSLabel.MatchString(label) {
			return false
		}
	}
	return true
}

func (s *linkPreviewService) preview(parent context.Context, raw string) (*linkPreviewResult, error) {
	target, err := validatedLinkPreviewURL(raw, nil)
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256([]byte(target.String()))
	key := previewPolicy.CachePrefix + hex.EncodeToString(hash[:])
	if cached := s.readCache(parent, key); cached != nil && parent.Err() == nil {
		return cached, nil
	}
	ctx, cancel := context.WithTimeout(parent, time.Duration(previewPolicy.TimeoutMS)*time.Millisecond)
	defer cancel()
	for hop := 0; hop <= previewPolicy.MaxRedirects && ctx.Err() == nil; hop++ {
		ip, err := s.publicIP(ctx, target.Hostname())
		if err != nil {
			return nil, err
		}
		if !ip.IsValid() || ctx.Err() != nil {
			return nil, nil
		}
		result, location := s.fetchHop(ctx, target, ip)
		if ctx.Err() != nil {
			return nil, nil
		}
		if location != "" {
			target, err = validatedLinkPreviewURL(location, target)
			if err != nil {
				return nil, err
			}
			continue
		}
		if result != nil {
			s.writeCache(parent, key, result)
		}
		return result, nil
	}
	return nil, nil
}

func (s *linkPreviewService) publicIP(ctx context.Context, host string) (netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip, nil // Literal addresses are checked before cache lookup and on every redirect.
	}
	name := strings.TrimSuffix(host, ".") + "."
	ips, err := s.lookup(ctx, "ip", name)
	if err != nil || len(ips) == 0 {
		return netip.Addr{}, nil
	}
	for _, ip := range ips {
		if !previewPublicIP(ip) {
			return netip.Addr{}, errLinkPreviewBlocked
		}
	}
	return ips[0], nil
}

func (s *linkPreviewService) readCache(parent context.Context, key string) *linkPreviewResult {
	metrics := requestTelemetryFrom(parent).telemetry
	if s.cache == nil {
		metrics.recordCache("degraded")
		return nil
	}
	ctx, cancel := context.WithTimeout(parent, time.Duration(previewPolicy.CacheTimeoutMS)*time.Millisecond)
	defer cancel()
	raw, err := s.cache.get(ctx, key)
	if err != nil {
		if errors.Is(err, redis.Nil) {
			metrics.recordCache("miss")
		} else {
			metrics.recordCache("degraded")
		}
		return nil
	}
	var preview linkPreviewResult
	if len(raw) > previewPolicy.MaxURLBytes*8 || json.Unmarshal([]byte(raw), &preview) != nil ||
		preview.Title == "" || utf8.RuneCountInString(preview.Title) > previewPolicy.TitleChars ||
		utf8.RuneCountInString(preview.Description) > previewPolicy.DescriptionChars ||
		utf8.RuneCountInString(preview.SiteName) > previewPolicy.SiteNameChars {
		metrics.recordCache("miss")
		return nil
	}
	target, err := validatedLinkPreviewURL(preview.URL, nil)
	if err != nil {
		metrics.recordCache("miss")
		return nil
	}
	preview.URL = target.String()
	metrics.recordCache("hit")
	return &preview
}

func (s *linkPreviewService) writeCache(parent context.Context, key string, result *linkPreviewResult) {
	if s.cache == nil {
		return
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(parent, time.Duration(previewPolicy.CacheTimeoutMS)*time.Millisecond)
	defer cancel()
	_ = s.cache.set(ctx, key, string(raw), time.Duration(previewPolicy.CacheTTLSeconds)*time.Second)
}

func linkPreviewRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, service *linkPreviewService) bool {
	if r.Method != http.MethodGet || r.URL.EscapedPath() != "/api/v2/links/preview" {
		return false
	}
	if _, ok := interactionActor(w, r, codec, repo); !ok {
		return true
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	raw := query["url"]
	if err != nil || len(raw) != 1 {
		respond(w, 400, 40001, "url 参数错误", nil)
		return true
	}
	result, err := service.preview(r.Context(), raw[0])
	if err != nil {
		respond(w, 400, 40001, "url 参数错误", nil)
		return true
	}
	respond(w, 200, 200, "success", struct {
		Preview *linkPreviewResult `json:"preview"`
	}{result})
	return true
}
