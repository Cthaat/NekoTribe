package server

import (
	"fmt"
	"strings"
	"testing"
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
func TestConfigRejectsInvalid(t *testing.T) {
	for _, tc := range []struct{ key, value string }{{"ACCESS_SECRET", ""}, {"REFRESH_SECRET", ""}, {"GO_BACKEND_PORT", "0"}, {"PORT", "65536"}, {"ORACLE_PORT", "-1"}, {"ORACLE_HOST", ""}, {"ORACLE_SERVICE_NAME", ""}, {"ORACLE_USER", ""}, {"ORACLE_PASSWORD", ""}, {"ORACLE_POOL_MIN", "x"}, {"ORACLE_POOL_MIN", "11"}, {"ORACLE_POOL_MAX", "0"}} {
		t.Run(tc.key+tc.value, func(t *testing.T) {
			env := validEnv()
			env[tc.key] = tc.value
			if _, e := LoadConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok }); e == nil {
				t.Fatal("accepted invalid config")
			}
		})
	}
}
