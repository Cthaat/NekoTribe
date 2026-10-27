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
}

func (c Config) String() string   { return "ServerConfig [redacted]" }
func (c Config) GoString() string { return c.String() }

var errConfig = errors.New("invalid server configuration")

func LoadConfig(lookup func(string) (string, bool)) (Config, error) {
	get := func(key string) string { value, _ := lookup(key); return value }
	c := Config{Host: get("HOST"), AccessKey: get("ACCESS_SECRET"), RefreshKey: get("REFRESH_SECRET"), OracleHost: get("ORACLE_HOST"), OracleService: get("ORACLE_SERVICE_NAME"), OracleUser: get("ORACLE_USER"), OraclePassword: get("ORACLE_PASSWORD")}
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
	if c.OraclePort, err = configInt(get("ORACLE_PORT"), 1521, 1, 65535); err != nil {
		return Config{}, err
	}
	if c.PoolMin, err = configInt(get("ORACLE_POOL_MIN"), 2, 0, 10000); err != nil {
		return Config{}, err
	}
	if c.PoolMax, err = configInt(get("ORACLE_POOL_MAX"), 10, 1, 10000); err != nil || c.PoolMin > c.PoolMax {
		return Config{}, errConfig
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
