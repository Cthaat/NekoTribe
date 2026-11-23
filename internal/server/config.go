package server

import (
	"errors"
	"strconv"
	"strings"
)

type Config struct {
	Host                                                  string
	Port                                                  int
	AccessKey, RefreshKey                                 string
	OracleHost, OracleService, OracleUser, OraclePassword string
	OraclePort, PoolMin, PoolMax                          int
	Cors                                                  CorsPolicy
	Refresh                                               RefreshConfig
}

func (c Config) String() string   { return "ServerConfig [redacted]" }
func (c Config) GoString() string { return c.String() }

var errConfig = errors.New("invalid server configuration")

func sharedNativeEnv(lookup func(string) (string, bool), key string) string {
	if value, exists := lookup("NUXT_" + key); exists {
		return value
	}
	value, _ := lookup(key)
	return value
}

func LoadConfig(lookup func(string) (string, bool)) (Config, error) {
	get := func(key string) string { value, _ := lookup(key); return value }
	shared := func(key string) string { return sharedNativeEnv(lookup, key) }
	c := Config{Host: get("HOST"), AccessKey: shared("ACCESS_SECRET"), RefreshKey: shared("REFRESH_SECRET"), OracleHost: shared("ORACLE_HOST"), OracleService: shared("ORACLE_SERVICE_NAME"), OracleUser: shared("ORACLE_USER"), OraclePassword: shared("ORACLE_PASSWORD")}
	if c.Host == "" {
		c.Host = "127.0.0.1"
	}
	port := get("GO_BACKEND_PORT")
	if port == "" {
		port = get("PORT")
	}
	var err error
	if c.Port, err = configInt(port, 30006, 1, 65535); err != nil {
		return Config{}, err
	}
	if c.OraclePort, err = configInt(shared("ORACLE_PORT"), 1521, 1, 65535); err != nil {
		return Config{}, err
	}
	if c.PoolMin, err = configInt(shared("ORACLE_POOL_MIN"), 2, 0, 10000); err != nil {
		return Config{}, err
	}
	if c.PoolMax, err = configInt(shared("ORACLE_POOL_MAX"), 10, 1, 10000); err != nil || c.PoolMin > c.PoolMax {
		return Config{}, errConfig
	}
	sessionTTL := func(key string, fallback int) (int, error) {
		value, exists := lookup("NUXT_" + key)
		if !exists {
			value, exists = lookup(key)
		}
		if !exists {
			return fallback, nil
		}
		value = strings.Trim(value, " \t\r\n\f\v")
		if value == "" {
			return 0, errConfig
		}
		return configInt(value, fallback, 1, 2147483647)
	}
	if c.Refresh.AccessSeconds, err = sessionTTL("ACCESS_EXPIRES_IN", 900); err != nil {
		return Config{}, errConfig
	}
	if c.Refresh.RefreshSeconds, err = sessionTTL("REFRESH_EXPIRES_IN", 2592000); err != nil {
		return Config{}, errConfig
	}
	// The Oracle session constraint requires refresh expiry after access expiry.
	// Bound seconds also keep the later seconds-to-Duration conversion safe.
	if c.Refresh.RefreshSeconds <= c.Refresh.AccessSeconds {
		return Config{}, errConfig
	}
	c.Refresh.CookieSecure = shared("COOKIE_SECURE") == "true"
	c.Refresh.Storage = storageURLConfig(lookup)
	c.Refresh.LocalStorage = localStorageConfig(lookup)
	c.Refresh.ModerationAllowAll = get("MODERATION_ALLOW_ALL")
	c.Refresh.ModerationAdminAccounts = get("MODERATION_ADMIN_ACCOUNTS")
	c.Refresh.AIModelConfig = get("AI_MODEL_CONFIG_JSON")
	c.Refresh.sentiment = configuredSentiment(get)
	c.Refresh.userProvider = configuredUserProvider(get)
	c.Refresh.webRTCIce = configuredWebRTCIce(get)
	c.Refresh.passkeys = configuredPasskeys(get("WEBAUTHN_RP_ID"), get("WEBAUTHN_ORIGINS"))
	c.Refresh.githubOAuth = configuredGitHubOAuth(get("GITHUB_OAUTH_CLIENT_ID"), get("GITHUB_OAUTH_CLIENT_SECRET"), get("GITHUB_OAUTH_REDIRECT_URI"))
	c.Refresh.metricsToken = get(observabilityPolicy.TokenEnvironmentVariable)
	if path := get("AI_MODEL_CONFIG_FILE"); path != "" {
		c.Refresh.aiModelFile = &aiModelFile{path: path}
	}
	c.Refresh.aiCredential = func(name string) (string, error) {
		value, ok := lookup(name)
		if !ok {
			return "", errConfig
		}
		return value, nil
	}
	c.Refresh.otpMailer = smtpFromLookup(lookup)
	switch strings.ToLower(strings.TrimSpace(get("TRUST_PROXY"))) {
	case "1", "true", "yes", "on":
		c.Refresh.TrustProxy = true
	}
	for _, value := range []string{c.Host, c.AccessKey, c.RefreshKey, c.OracleHost, c.OracleService, c.OracleUser, c.OraclePassword} {
		if strings.TrimSpace(value) == "" {
			return Config{}, errConfig
		}
	}
	if strings.ContainsAny(c.OracleHost, "()/= \t\r\n") || strings.ContainsAny(c.OracleService, "()/= \t\r\n") {
		return Config{}, errConfig
	}
	for _, key := range []string{"CORS_ALLOWED_ORIGINS", "NUXT_CORS_ALLOWED_ORIGINS"} {
		for _, value := range strings.Split(get(key), ",") {
			if origin := normalizeOrigin(strings.TrimSpace(value)); origin != "" && !contains(c.Cors.Origins, origin) {
				c.Cors.Origins = append(c.Cors.Origins, origin)
			}
		}
	}
	local, configured := lookup("NUXT_CORS_ALLOW_LOCALHOST_ORIGINS")
	if !configured {
		local, configured = lookup("CORS_ALLOW_LOCALHOST_ORIGINS")
	}
	c.Cors.Localhost = local == "true" || (!configured && get("NODE_ENV") == "development")
	return c, nil
}
func configInt(raw string, fallback, min, max int) (int, error) {
	if raw == "" {
		return fallback, nil
	}
	n, e := strconv.Atoi(raw)
	if e != nil || n < min || n > max {
		return 0, errConfig
	}
	return n, nil
}
