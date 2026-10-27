package server

import (
	"errors"
	"net"
	"net/url"
	"path"
	"strings"
)

// StorageURLPolicy describes public addresses only; it never opens files.
type StorageURLPolicy struct {
	PublicBase, BaseURL, CDNBaseURL string
	invalidPublicBase               bool
}

func (StorageURLPolicy) String() string     { return "StorageURLPolicy [redacted]" }
func (p StorageURLPolicy) GoString() string { return p.String() }

func storageURLConfig(lookup func(string) (string, bool)) StorageURLPolicy {
	get := func(key string) string { value, _ := lookup(key); return strings.TrimFunc(value, jsTrimSpace) }
	base := strings.ReplaceAll(get("STORAGE_PUBLIC_BASE"), `\`, "/")
	invalidBase := (base != "" && strings.Trim(base, "/") == "") || strings.HasPrefix(base, "//")
	base = strings.TrimRight(base, "/")
	if base == "" {
		base = "/storage"
	} else if !strings.HasPrefix(base, "/") {
		base = "/" + base
	}
	return StorageURLPolicy{PublicBase: base, BaseURL: strings.TrimRight(get("BASE_URL"), "/"), CDNBaseURL: strings.TrimRight(get("STORAGE_CDN_BASE_URL"), "/"), invalidPublicBase: invalidBase}
}

func hasStorageCredentials(policy StorageURLPolicy) bool {
	for _, candidate := range []string{policy.BaseURL, policy.CDNBaseURL} {
		if parsed, err := url.Parse(candidate); err == nil && parsed.User != nil {
			password, _ := parsed.User.Password()
			if parsed.User.Username() != "" || password != "" {
				return true
			}
		}
	}
	return false
}

func normalizeStorageKey(value string) (string, error) {
	value = strings.TrimLeft(strings.ReplaceAll(value, `\`, "/"), "/")
	clean := path.Clean(value)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") || strings.Contains(clean, "/../") {
		return "", errors.New("invalid storage path")
	}
	if strings.HasSuffix(value, "/") && !strings.HasSuffix(clean, "/") {
		clean += "/"
	}
	return clean, nil
}

func sameURLOrigin(a, b *url.URL) bool {
	if a.Scheme == "" || b.Scheme == "" || a.Host == "" || b.Host == "" || !strings.EqualFold(a.Scheme, b.Scheme) || !strings.EqualFold(a.Hostname(), b.Hostname()) {
		return false
	}
	port := func(u *url.URL) string {
		if u.Port() != "" {
			return u.Port()
		}
		if strings.EqualFold(u.Scheme, "https") {
			return "443"
		}
		if strings.EqualFold(u.Scheme, "http") {
			return "80"
		}
		return ""
	}
	return port(a) == port(b)
}

func normalizeAvatarURL(config StorageURLPolicy, input string) (string, error) {
	if config.invalidPublicBase || strings.HasPrefix(config.PublicBase, "//") || config.PublicBase == "/" {
		return "", errors.New("invalid public storage base path")
	}
	if hasStorageCredentials(config) {
		return "", errors.New("public storage URL contains credentials")
	}
	if config.PublicBase == "" {
		config.PublicBase = "/storage"
	}
	value := strings.TrimFunc(input, jsTrimSpace)
	base := config.CDNBaseURL
	if base == "" {
		base = config.BaseURL
	}
	build := func(key string) (string, error) {
		key, err := normalizeStorageKey(key)
		if err != nil {
			return "", err
		}
		relative := config.PublicBase + "/" + key
		if base == "" {
			return relative, nil
		}
		origin, err := url.Parse(base + "/")
		if err != nil || origin.Scheme == "" || origin.Host == "" {
			return "", errors.New("invalid storage base URL")
		}
		origin.Scheme = strings.ToLower(origin.Scheme)
		host, port := strings.ToLower(origin.Hostname()), origin.Port()
		if (origin.Scheme == "https" && port == "443") || (origin.Scheme == "http" && port == "80") {
			port = ""
		}
		if port != "" {
			origin.Host = net.JoinHostPort(host, port)
		} else if strings.Contains(host, ":") {
			origin.Host = "[" + host + "]"
		} else {
			origin.Host = host
		}
		ref, err := url.Parse(relative)
		if err != nil {
			return "", errors.New("invalid storage URL")
		}
		return origin.ResolveReference(ref).String(), nil
	}
	if value == "" || value == "/default-avatar.png" || value == "default-avatar.png" {
		return build("default-avatar.png")
	}
	prefixes := []string{config.PublicBase + "/", "/storage/", "/uploads/", "/upload/"}
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, prefix) {
			return build(strings.TrimPrefix(value, prefix))
		}
	}
	if base == "" {
		return value, nil
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return value, nil
	}
	origin, err := url.Parse(base + "/")
	if err != nil || !sameURLOrigin(parsed, origin) {
		return value, nil
	}
	pathname := parsed.EscapedPath()
	for _, prefix := range prefixes {
		if strings.HasPrefix(pathname, prefix) {
			return build(strings.TrimPrefix(pathname, prefix))
		}
	}
	return value, nil
}
