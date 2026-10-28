package ai

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type transportVector struct {
	ID                    string            `json:"id"`
	Selection             Selection         `json:"selection"`
	Request               json.RawMessage   `json:"request"`
	Credentials           map[string]string `json:"credentials"`
	ExpectedPath          string            `json:"expectedPath"`
	ExpectedBody          json.RawMessage   `json:"expectedBody"`
	ExpectedAuthorization string            `json:"expectedAuthorization"`
	Status                int               `json:"status"`
	Response              json.RawMessage   `json:"response"`
	ResponseText          *string           `json:"responseText"`
	Expected              json.RawMessage   `json:"expected"`
	ExpectedError         string            `json:"expectedError"`
	NoNetwork             bool              `json:"noNetwork"`
}

// Fail precisely the first write of the second POST on a reused connection.
// Go's HTTP/1 transport otherwise transparently retries this zero-byte failure
// when NewRequest installed a replayable GetBody callback.
type failReusedPostConn struct {
	net.Conn
	writes *atomic.Int32
}

func (c *failReusedPostConn) Write(data []byte) (int, error) {
	if bytes.HasPrefix(data, []byte("POST ")) && c.writes.Add(1) == 2 {
		return 0, io.ErrClosedPipe
	}
	return c.Conn.Write(data)
}

type testRoundTripper func(*http.Request) (*http.Response, error)

func (f testRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestTransportOneAttemptAndOwnedHTTP1(t *testing.T) {
	base := transportVectors(t)[1]
	t.Run("failed reused connection is not replayed", func(t *testing.T) {
		var calls atomic.Int32
		var writes atomic.Int32
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls.Add(1)
			_, _ = io.Copy(io.Discard, r.Body)
			_, _ = w.Write(base.Response)
		}))
		defer server.Close()
		transport, _ := NewTransport(nil)
		tr := transport.client.Transport.(*http.Transport)
		defer tr.CloseIdleConnections()
		tr.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := (&net.Dialer{}).DialContext(ctx, network, address)
			if err != nil {
				return nil, err
			}
			return &failReusedPostConn{Conn: conn, writes: &writes}, nil
		}
		s := base.Selection
		s.BaseURL = server.URL
		if _, err := transport.Infer(context.Background(), s, base.Request); err != nil {
			t.Fatal(err)
		}
		_, err := transport.Infer(context.Background(), s, base.Request)
		assertTransportError(t, err, "PROVIDER_UNAVAILABLE")
		if calls.Load() != 1 || writes.Load() != 2 {
			t.Fatalf("request replayed: %d provider calls, %d POST writes", calls.Load(), writes.Load())
		}
	})
	t.Run("TLS negotiates only HTTP1", func(t *testing.T) {
		var version atomic.Int32
		server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			version.Store(int32(r.ProtoMajor))
			_, _ = w.Write(base.Response)
		}))
		server.EnableHTTP2 = true
		server.StartTLS()
		defer server.Close()
		transport, _ := NewTransport(nil)
		tr := transport.client.Transport.(*http.Transport)
		defer tr.CloseIdleConnections()
		roots := x509.NewCertPool()
		roots.AddCert(server.Certificate())
		tr.TLSClientConfig = &tls.Config{RootCAs: roots}
		s := base.Selection
		s.BaseURL = server.URL
		if _, err := transport.Infer(context.Background(), s, base.Request); err != nil {
			t.Fatal(err)
		}
		if version.Load() != 1 {
			t.Fatalf("negotiated HTTP/%d; one-attempt transport must use HTTP/1", version.Load())
		}
	})
	t.Run("global default transport is not assumed", func(t *testing.T) {
		previous := http.DefaultTransport
		http.DefaultTransport = testRoundTripper(func(*http.Request) (*http.Response, error) {
			t.Error("global transport used")
			return nil, errors.New("never-print")
		})
		defer func() { http.DefaultTransport = previous }()
		defer func() {
			if recovered := recover(); recovered != nil {
				t.Fatalf("constructor assumes global transport concrete type: %v", recovered)
			}
		}()
		if _, err := NewTransport(nil); err != nil {
			t.Fatal(err)
		}
	})
}

func TestTransportBoundaries(t *testing.T) {
	base := transportVectors(t)[1]
	variants := []struct {
		name, body, encoding, code string
		status                     int
	}{
		{name: "invalid UTF8", body: string([]byte{0xff}), code: "INVALID_PROVIDER_RESPONSE"},
		{name: "BOM", body: "\xef\xbb\xbf" + string(base.Response), code: "INVALID_PROVIDER_RESPONSE"},
		{name: "encoding", body: string(base.Response), encoding: "gzip", code: "INVALID_PROVIDER_RESPONSE"},
		{name: "size", body: strings.Repeat("x", transportLimit+1), code: "RESPONSE_TOO_LARGE"},
		{name: "redirect", status: 302, body: "never-print-secret", code: "PROVIDER_REJECTED"},
		{name: "rejected", status: 500, body: "never-print-secret", code: "PROVIDER_REJECTED"},
	}
	for _, v := range variants {
		t.Run(v.name, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if v.encoding != "" {
					w.Header().Set("Content-Encoding", v.encoding)
				}
				w.Header().Set("Location", "/followed")
				status := v.status
				if status == 0 {
					status = 200
				}
				w.WriteHeader(status)
				_, _ = w.Write([]byte(v.body))
			}))
			defer server.Close()
			s := base.Selection
			s.BaseURL = server.URL
			transport, _ := NewTransport(nil)
			_, err := transport.Infer(context.Background(), s, base.Request)
			assertTransportError(t, err, v.code)
			if calls != 1 {
				t.Fatalf("%d attempts", calls)
			}
		})
	}
	for _, bodyWait := range []bool{false, true} {
		t.Run(fmt.Sprintf("timeout cancel body=%v", bodyWait), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if bodyWait {
					w.WriteHeader(200)
					_, _ = w.Write([]byte("{"))
					w.(http.Flusher).Flush()
				}
				select {
				case <-r.Context().Done():
				case <-time.After(300 * time.Millisecond):
				}
			}))
			defer server.Close()
			s := base.Selection
			s.BaseURL = server.URL
			transport, _ := NewTransport(nil, 25)
			_, err := transport.Infer(context.Background(), s, base.Request)
			assertTransportError(t, err, "TIMEOUT")
			transport, _ = NewTransport(nil)
			ctx, cancel := context.WithCancel(context.Background())
			time.AfterFunc(25*time.Millisecond, cancel)
			_, err = transport.Infer(ctx, s, base.Request)
			assertTransportError(t, err, "CANCELLED")
		})
	}
	t.Run("resolver and request precedence", func(t *testing.T) {
		reference := "KEY"
		s := base.Selection
		s.APIKeyEnv = &reference
		calls := 0
		transport, _ := NewTransport(func(string) (string, error) { calls++; return "", errors.New("never-print http://private") })
		_, err := transport.Infer(context.Background(), s, []byte(`{"messages":null}`))
		assertTransportError(t, err, "INVALID_REQUEST")
		if calls != 0 {
			t.Fatal("resolver before validation")
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err = transport.Infer(ctx, s, base.Request)
		assertTransportError(t, err, "CANCELLED")
		if calls != 0 {
			t.Fatal("resolver on cancellation")
		}
		_, err = transport.Infer(context.Background(), s, base.Request)
		assertTransportError(t, err, "MISSING_CREDENTIAL")
		for _, value := range []string{"has space", "换行", string([]byte{0xff})} {
			transport, _ = NewTransport(func(string) (string, error) { return value, nil })
			_, err = transport.Infer(context.Background(), s, base.Request)
			assertTransportError(t, err, "MISSING_CREDENTIAL")
		}
		for _, timeout := range []int{0, -1, 300001} {
			_, err = NewTransport(nil, timeout)
			assertTransportError(t, err, "INVALID_REQUEST")
		}
	})
	t.Run("detached snapshot and integral usage", func(t *testing.T) {
		var seen map[string]any
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_ = json.NewDecoder(r.Body).Decode(&seen)
			_, _ = w.Write([]byte(`{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1.0,"completion_tokens":1e0}}`))
		}))
		defer server.Close()
		s := cloneSelection(base.Selection)
		s.BaseURL = server.URL
		reference := "KEY"
		s.APIKeyEnv = &reference
		transport, _ := NewTransport(func(string) (string, error) {
			s.BaseURL = "http://127.0.0.1:1"
			s.Model = "changed"
			s.Capabilities[0] = "vision"
			reference = "changed"
			return "never-print-key", nil
		})
		result, err := transport.Infer(context.Background(), s, base.Request)
		if err != nil {
			t.Fatal(err)
		}
		if seen["model"] != base.Selection.Model || *result.Usage.InputTokens != 1 || *result.Usage.OutputTokens != 1 {
			t.Fatalf("snapshot/usage mismatch: %v %v", seen, result)
		}
	})
	t.Run("unavailable", func(t *testing.T) {
		s := base.Selection
		s.BaseURL = "http://127.0.0.1:1"
		transport, _ := NewTransport(nil)
		_, err := transport.Infer(context.Background(), s, base.Request)
		assertTransportError(t, err, "PROVIDER_UNAVAILABLE")
	})
}
func transportVectors(t *testing.T) []transportVector {
	t.Helper()
	data, err := os.ReadFile("../../contracts/scenarios/ai-inference-transport.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []transportVector `json:"cases"`
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) != 55 {
		t.Fatalf("got %d vectors", len(fixture.Cases))
	}
	history, err := os.ReadFile("../../contracts/scenarios/ai-tool-history.json")
	if err != nil {
		t.Fatal(err)
	}
	var historyFixture struct {
		Cases []transportVector `json:"cases"`
	}
	if err := json.Unmarshal(history, &historyFixture); err != nil || len(historyFixture.Cases) != 24 {
		t.Fatal("invalid tool history vectors", err)
	}
	fixture.Cases = append(fixture.Cases, historyFixture.Cases...)
	return fixture.Cases
}
func assertTransportError(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil || err.Error() != code {
		t.Fatalf("expected %s, got %v", code, err)
	}
	if strings.Contains(fmt.Sprintf("%+v", err), "never-print") {
		t.Fatal("unsafe error")
	}
}
func assertJSONEqual(t *testing.T, got, expected []byte) {
	t.Helper()
	var a, b any
	if json.Unmarshal(got, &a) != nil || json.Unmarshal(expected, &b) != nil || !reflect.DeepEqual(a, b) {
		t.Fatalf("JSON mismatch\ngot %s\nwant %s", got, expected)
	}
}
func TestTransportCommonVectors(t *testing.T) {
	for _, v := range transportVectors(t) {
		t.Run(v.ID, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != "POST" || r.URL.Path != v.ExpectedPath {
					t.Errorf("unexpected method/path %s %s", r.Method, r.URL.Path)
				}
				if r.Header.Get("Authorization") != v.ExpectedAuthorization || r.Header.Get("Accept-Encoding") != "identity" || r.Header.Get("Cookie") != "" {
					t.Error("unexpected headers")
				}
				body, _ := io.ReadAll(r.Body)
				if v.ExpectedBody != nil {
					assertJSONEqual(t, body, v.ExpectedBody)
				}
				w.WriteHeader(v.Status)
				if v.ResponseText != nil {
					_, _ = w.Write([]byte(*v.ResponseText))
				} else {
					_, _ = w.Write(v.Response)
				}
			}))
			defer server.Close()
			path := v.Selection.BaseURL[strings.Index(v.Selection.BaseURL[7:], "/")+7:]
			v.Selection.BaseURL = server.URL + path
			transport, err := NewTransport(func(ref string) (string, error) { return v.Credentials[ref], nil })
			if err != nil {
				t.Fatal(err)
			}
			result, err := transport.Infer(context.Background(), v.Selection, v.Request)
			if v.ExpectedError != "" {
				assertTransportError(t, err, v.ExpectedError)
			} else {
				if err != nil {
					t.Fatal(err)
				}
				encoded, _ := json.Marshal(result)
				assertJSONEqual(t, encoded, v.Expected)
			}
			expectedCalls := 1
			if v.NoNetwork {
				expectedCalls = 0
			}
			if calls != expectedCalls {
				t.Errorf("got %d calls, expected %d", calls, expectedCalls)
			}
		})
	}
}

func TestToolProposalRoundTrip(t *testing.T) {
	vectors := transportVectors(t)
	for _, adapter := range []string{"ollama", "openai-compatible"} {
		t.Run(adapter, func(t *testing.T) {
			firstID, lastID := "TRANSPORT-O03", "TRANSPORT-O01"
			if adapter == "openai-compatible" {
				firstID, lastID = "TRANSPORT-C03", "TRANSPORT-C01"
			}
			var first, last transportVector
			for _, v := range vectors {
				if v.ID == firstID {
					first = v
				}
				if v.ID == lastID {
					last = v
				}
			}
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				count := calls.Add(1)
				var body map[string]any
				if json.NewDecoder(r.Body).Decode(&body) != nil {
					t.Error("invalid request body")
					return
				}
				if count == 2 {
					messages := body["messages"].([]any)
					assistant := messages[len(messages)-2].(map[string]any)
					result := messages[len(messages)-1].(map[string]any)
					call := assistant["tool_calls"].([]any)[0].(map[string]any)
					fn := call["function"].(map[string]any)
					if fn["name"] != "search_public" || result["content"] != "synthetic tool result" {
						t.Error("incorrect tool history")
					}
					if adapter == "ollama" && result["tool_name"] != "search_public" {
						t.Error("incorrect Ollama tool name")
					}
					if adapter == "openai-compatible" && result["tool_call_id"] != "call-1" {
						t.Error("incorrect tool call ID")
					}
				}
				w.Header().Set("Content-Type", "application/json")
				if count == 1 {
					_, _ = w.Write(first.Response)
				} else {
					_, _ = w.Write(last.Response)
				}
			}))
			defer server.Close()
			s := first.Selection
			s.BaseURL = server.URL
			s.APIKeyEnv = nil
			transport, err := NewTransport(nil)
			if err != nil {
				t.Fatal(err)
			}
			proposal, err := transport.Infer(context.Background(), s, first.Request)
			if err != nil || len(proposal.ToolCalls) != 1 {
				t.Fatal("missing proposal", err)
			}
			var request map[string]any
			if err = json.Unmarshal(first.Request, &request); err != nil {
				t.Fatal(err)
			}
			messages := request["messages"].([]any)
			request["messages"] = append(messages, map[string]any{"role": "assistant", "content": proposal.Text, "toolCalls": proposal.ToolCalls}, map[string]any{"role": "tool", "content": "synthetic tool result", "toolCallId": proposal.ToolCalls[0].ID})
			encoded, err := json.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			answer, err := transport.Infer(context.Background(), s, encoded)
			if err != nil || answer.FinishReason != "stop" || answer.Text != "合成回复" || calls.Load() != 2 {
				t.Fatal("round trip failed", err)
			}
		})
	}
}

func TestTransportUnicodeAndHTMLEscaping(t *testing.T) {
	base := transportVectors(t)[1]
	transport, _ := NewTransport(nil)
	for _, raw := range []string{`{"messages":[{"role":"user","content":"\ud800"}]}`, `{"messages":[{"role":"user","content":"\udc00"}]}`, `{"messages":[{"role":"user","content":""}],"responseSchema":{"type":"object","\ud800":"value"}}`} {
		_, err := transport.Infer(context.Background(), base.Selection, []byte(raw))
		assertTransportError(t, err, "INVALID_REQUEST")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[{"index":0,"message":{"role":"assistant","content":"\ud800"},"finish_reason":"stop"}]}`))
	}))
	defer server.Close()
	s := base.Selection
	s.BaseURL = server.URL
	_, err := transport.Infer(context.Background(), s, base.Request)
	assertTransportError(t, err, "INVALID_PROVIDER_RESPONSE")
}
func TestTransportHTMLEscaping(t *testing.T) {
	base := transportVectors(t)[1]
	transport, _ := NewTransport(nil)
	s := base.Selection
	server2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		if len(data) > transportLimit {
			t.Error("escaped request too large")
		}
		_, _ = w.Write(base.Response)
	}))
	defer server2.Close()
	s.BaseURL = server2.URL
	request, _ := json.Marshal(map[string]any{"messages": []any{map[string]any{"role": "user", "content": strings.Repeat("&", 200000)}}})
	// This internal API's raw byte guard is independent of the HTTP encoding cap.
	request = []byte(strings.ReplaceAll(string(request), `\u0026`, "&"))
	if _, err := transport.Infer(context.Background(), s, request); err != nil {
		t.Fatal(err)
	}
}
