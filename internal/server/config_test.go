package server

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

func validEnv() map[string]string {
	return map[string]string{"ACCESS_SECRET": "secret-a", "REFRESH_SECRET": "secret-b", "ORACLE_HOST": "db.example", "ORACLE_PORT": "1521", "ORACLE_SERVICE_NAME": "APP", "ORACLE_USER": "user", "ORACLE_PASSWORD": "password", "ORACLE_POOL_MIN": "2", "ORACLE_POOL_MAX": "10"}
}
func TestConfigValidatesAndRedacts(t *testing.T) {
	env := validEnv()
	c, e := LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if e != nil {
		t.Fatal(e)
	}
	if c.Host != "127.0.0.1" || c.Port != 30006 || c.PoolMin != 2 || c.PoolMax != 10 {
		t.Fatal(c)
	}
	for _, format := range []string{"%v", "%+v", "%#v"} {
		v := fmt.Sprintf(format, c)
		for _, secret := range []string{"secret-a", "secret-b", "db.example", "password"} {
			if strings.Contains(v, secret) {
				t.Fatalf("leaked %s", secret)
			}
		}
	}
	env["PORT"] = "3000"
	env["GO_BACKEND_PORT"] = "30006"
	c, e = LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if e != nil || c.Port != 30006 {
		t.Fatal(c, e)
	}
}

func TestRefreshConfigRedactsSMTPSecrets(t *testing.T) {
	env := validEnv()
	env["SMTP_HOST"] = "mail.example.test"
	env["SMTP_PORT"] = "465"
	env["SMTP_USER"] = "sender@example.test"
	env["SMTP_PASS"] = "synthetic-mail-password"
	config, err := LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if err != nil {
		t.Fatal(err)
	}
	for _, format := range []string{"%v", "%+v", "%#v"} {
		if strings.Contains(fmt.Sprintf(format, config.Refresh), "synthetic-mail-password") {
			t.Fatal("refresh config exposed SMTP password")
		}
	}
}

func TestConfigAcceptsSharedNuxtVariables(t *testing.T) {
	env := validEnv()
	for key, value := range validEnv() {
		env["NUXT_"+key] = value
	}
	env["ORACLE_HOST"] = "different.example"
	delete(env, "ACCESS_SECRET")
	env["NUXT_ORACLE_PORT"] = "1522"
	env["NUXT_COOKIE_SECURE"] = "true"
	lookup := func(key string) (string, bool) { value, exists := env[key]; return value, exists }
	config, err := LoadConfig(lookup)
	if err != nil || config.OracleHost != "db.example" || config.OraclePort != 1522 ||
		config.AccessKey != "secret-a" || !config.Refresh.CookieSecure {
		t.Fatal("shared native configuration did not resolve", err)
	}
	maintenance, err := skillOracleConfig(lookup)
	if err != nil || maintenance.OracleHost != config.OracleHost || maintenance.OraclePort != config.OraclePort {
		t.Fatal("maintenance resolved a different Oracle address", err)
	}
	env["NUXT_ORACLE_PASSWORD"] = ""
	if _, err := LoadConfig(lookup); err == nil {
		t.Fatal("empty prefixed credential incorrectly used the legacy fallback")
	}
}

func TestConfigRejectsInvalid(t *testing.T) {
	for _, tc := range []struct{ key, value string }{{"ACCESS_SECRET", ""}, {"REFRESH_SECRET", ""}, {"GO_BACKEND_PORT", "0"}, {"PORT", "65536"}, {"ORACLE_PORT", "-1"}, {"ORACLE_HOST", ""}, {"ORACLE_SERVICE_NAME", ""}, {"ORACLE_USER", ""}, {"ORACLE_PASSWORD", ""}, {"ORACLE_POOL_MIN", "x"}, {"ORACLE_POOL_MIN", "11"}, {"ORACLE_POOL_MAX", "0"}, {"ACCESS_EXPIRES_IN", "0"}, {"REFRESH_EXPIRES_IN", "-1"}, {"NUXT_ACCESS_EXPIRES_IN", "invalid"}, {"REFRESH_EXPIRES_IN", "2147483648"}} {
		t.Run(tc.key+tc.value, func(t *testing.T) {
			env := validEnv()
			env[tc.key] = tc.value
			if _, e := LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok }); e == nil {
				t.Fatal("accepted invalid config")
			}
		})
	}
}

func TestRefreshConfig(t *testing.T) {
	env := validEnv()
	lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
	c, err := LoadConfig(lookup)
	if err != nil || c.Refresh.AccessSeconds != 900 || c.Refresh.RefreshSeconds != 2592000 || c.Refresh.CookieSecure {
		t.Fatal("default refresh config", err)
	}
	env["ACCESS_EXPIRES_IN"], env["REFRESH_EXPIRES_IN"], env["NUXT_ACCESS_EXPIRES_IN"], env["COOKIE_SECURE"] = "30", "60", "45", "true"
	c, err = LoadConfig(lookup)
	if err != nil || c.Refresh.AccessSeconds != 45 || c.Refresh.RefreshSeconds != 60 || !c.Refresh.CookieSecure {
		t.Fatal("custom refresh config", err)
	}
	env["COOKIE_SECURE"] = "TRUE"
	c, err = LoadConfig(lookup)
	if err != nil || c.Refresh.CookieSecure {
		t.Fatal("cookie secure differs from Nuxt", err)
	}
}

func TestConfigLoadsStorageURLs(t *testing.T) {
	env := validEnv()
	env["STORAGE_PUBLIC_BASE"] = "/media"
	env["STORAGE_CDN_BASE_URL"] = "https://user:private-url-secret@cdn.example"
	c, err := LoadConfig(func(k string) (string, bool) { value, ok := env[k]; return value, ok })
	if err != nil {
		t.Fatal(err)
	}
	for _, format := range []string{"%v", "%+v", "%#v"} {
		if strings.Contains(fmt.Sprintf(format, c.Refresh.Storage), "private-url-secret") {
			t.Fatal("storage policy leaked credentials")
		}
	}
	if _, err := normalizeAvatarURL(c.Refresh.Storage, "/uploads/a.png"); err == nil {
		t.Fatal("public URL accepted credentials")
	}
}

func TestTrustProxyRequiresExplicitRecognizedValue(t *testing.T) {
	for _, tc := range []struct {
		raw      string
		expected bool
	}{{"", false}, {" TRUE ", true}, {"yes", true}, {"on", true}, {"1", true}, {"false", false}, {"other", false}} {
		env := validEnv()
		env["TRUST_PROXY"] = tc.raw
		config, err := LoadConfig(func(k string) (string, bool) { value, ok := env[k]; return value, ok })
		if err != nil || config.Refresh.TrustProxy != tc.expected {
			t.Fatalf("TRUST_PROXY=%q expected %v", tc.raw, tc.expected)
		}
	}
}

func TestRefreshTTLRelationAndDurationBoundary(t *testing.T) {
	for _, tc := range []struct {
		name, access, refresh string
		valid                 bool
	}{
		{"equal", "300", "300", false},
		{"refresh shorter", "301", "300", false},
		{"refresh longer", "300", "301", true},
		{"ASCII whitespace and decimal prefix", " +030 ", " 60 ", true},
		{"explicit blank", "300", "", false},
		{"non-decimal", "1e2", "301", false},
		{"maximum duration", "2147483646", "2147483647", true},
		{"over maximum", "1", "2147483648", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := validEnv()
			env["ACCESS_EXPIRES_IN"], env["REFRESH_EXPIRES_IN"] = tc.access, tc.refresh
			c, err := LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%t, err=%v", tc.valid, err)
			}
			if err == nil && (time.Duration(c.Refresh.RefreshSeconds)*time.Second <= 0 || time.Duration(c.Refresh.AccessSeconds)*time.Second <= 0) {
				t.Fatal("duration overflow")
			}
		})
	}
	env := validEnv()
	env["ACCESS_EXPIRES_IN"], env["NUXT_ACCESS_EXPIRES_IN"] = "30", ""
	if _, err := LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok }); err == nil {
		t.Fatal("explicitly empty canonical lifetime fell back to the legacy alias")
	}
}
