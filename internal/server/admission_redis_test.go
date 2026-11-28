package server

import (
	"context"
	"encoding/json"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// Start an isolated Redis-compatible process, never use deployment credentials or keys.
func localAdmissionRedis(t *testing.T) *redis.Client {
	t.Helper()
	binary, err := exec.LookPath("redis-server")
	if err != nil {
		binary, err = exec.LookPath("memurai")
		if err != nil {
			t.Skip("local Redis executable unavailable")
		}
	}
	socket, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := socket.Addr().(*net.TCPAddr)
	socket.Close()
	password, err := randomUUID()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	conf := filepath.Join(dir, "test.conf")
	if err = os.WriteFile(conf, []byte("bind 127.0.0.1\nport "+strconv.Itoa(addr.Port)+"\nsave \"\"\nappendonly no\nrequirepass "+password+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary, conf)
	cmd.Dir = dir
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	client := redis.NewClient(&redis.Options{Addr: addr.String(), Password: password, MaxRetries: -1})
	t.Cleanup(func() { _ = client.Close() })
	deadline := time.Now().Add(8 * time.Second)
	for client.Ping(context.Background()).Err() != nil {
		if time.Now().After(deadline) {
			t.Fatal("isolated Redis did not become ready")
		}
		time.Sleep(25 * time.Millisecond)
	}
	return client
}

func TestB01RedisWindow(t *testing.T) {
	client := localAdmissionRedis(t)
	ctx := context.Background()
	limiter := RedisOTPSendLimiter{client: client}
	for _, tc := range b01Vectors(t) {
		switch tc.ID {
		case "shared-race":
			t.Run(tc.ID, func(t *testing.T) {
				var sent int
				results := make(chan int, 24)
				for _, requests := range tc.Input.ParallelPerBackend {
					s, _, codec := newLoginFixture(t)
					handler := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{Admission: &limiter})
					for range requests {
						sent++
						go func() {
							w := httptest.NewRecorder()
							handler.ServeHTTP(w, httptest.NewRequest("POST", "/api/v2/auth/tokens", strings.NewReader("{}")))
							results <- w.Code
						}()
					}
				}
				var admitted int
				for range sent {
					switch status := <-results; status {
					case 400:
						admitted++ // Dispatched to the login handler with an empty body object.
					case 429:
					default:
						t.Errorf("unexpected HTTP status %d", status)
					}
				}
				if strconv.Itoa(admitted) != string(tc.Expect.Admitted) || strconv.Itoa(sent-admitted) != string(tc.Expect.Rejected) || strconv.Itoa(admitted) != string(tc.Expect.Dispatched) {
					t.Fatalf("admitted %d/%d", admitted, sent)
				}
			})
		case "last-slot", "synchronized-handoff", "window-expiry":
			t.Run(tc.ID, func(t *testing.T) {
				tier := classifyAdmission("GET", "posts")
				if tc.Input.Tier == "write" {
					tier = classifyAdmission("POST", "posts")
				}
				key := "neko:v2:admission:1:" + tier.name + ":192.0.2.8"
				if err := client.Set(ctx, key, tc.Input.Used, 10*time.Second).Err(); err != nil {
					t.Fatal(err)
				}
				var want []bool
				switch tc.ID {
				case "last-slot":
					want = []bool{true}
				default:
					if err := json.Unmarshal(tc.Expect.Admitted, &want); err != nil {
						t.Fatal(err)
					}
				}
				for i, allowed := range want {
					if tc.ID == "window-expiry" && i == 2 {
						if err := client.PExpireAt(ctx, key, time.Unix(1, 0)).Err(); err != nil {
							t.Fatal(err)
						}
					}
					ttl, err := client.PTTL(ctx, key).Result()
					if err != nil {
						t.Fatal(err)
					}
					got, err := limiter.admit(ctx, key, tier)
					if err != nil || got.admitted != allowed {
						t.Fatalf("attempt %d: %+v %v", i, got, err)
					}
					if !allowed && got.ttlMS > ttl.Milliseconds() {
						t.Fatal("denial extended deadline")
					}
					if tc.ID == "window-expiry" && i == 2 && got.remaining != tier.limit-1 {
						t.Fatal("window did not restart")
					}
				}
			})
		}
	}
}

func TestB01AdmissionExclusionsAndKeys(t *testing.T) {
	codec, _ := fixture(t)
	limiter := &admissionStub{result: admissionResult{false, 0, 1}}
	handler := NewHandlerWithConfig(codec, store(), CorsPolicy{}, RefreshConfig{Admission: limiter})
	for _, request := range []string{"GET /api/health", "OPTIONS /api/v2/posts", "GET /api/v2/integrations/sentiment-flow/config"} {
		method, path, _ := strings.Cut(request, " ")
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(method, path, nil))
	}
	if limiter.calls != 0 {
		t.Fatal("excluded route wrote a counter")
	}
	for _, tc := range []struct{ method, path, ip, want string }{
		{"GET", "/api/v2/posts?limit=7", "192.0.2.8:99", "read:192.0.2.8"},
		{"POST", "/api/v2/auth/otp", "192.0.2.9:99", "auth:192.0.2.9"},
		{"POST", "/api/v2/auth/otp", "[::ffff:192.0.2.8]:99", "auth:192.0.2.8"},
		{"GET", "/api/v2/posts", "[2001:0DB8:0::A]:99", "read:2001:db8::a"},
		{"GET", "/api/v2/posts", "", "read:unknown"},
	} {
		req := httptest.NewRequest(tc.method, tc.path, nil)
		req.RemoteAddr = tc.ip
		handler.ServeHTTP(httptest.NewRecorder(), req)
		if limiter.key != "neko:v2:admission:1:"+tc.want {
			t.Fatal(limiter.key)
		}
	}
}
