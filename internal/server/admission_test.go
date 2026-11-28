package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

type b01Case struct {
	ID    string
	Input struct {
		Request, Tier, PriorRegion, CurrentRegion string
		KnownFingerprint                          bool
		Used, TTLMS, DomainRetrySeconds           int64
		ParallelPerBackend                        map[string]int
		Sequence                                  []string
	}
	Expect struct {
		Tier                 string
		Status, Code         int
		EmailSchedules       json.RawMessage
		Limit, WindowSeconds int64
		Headers              map[string]int64
		Admitted             json.RawMessage
		Rejected, Dispatched json.RawMessage
	}
}

func b01Vectors(t *testing.T) []b01Case {
	t.Helper()
	data, err := os.ReadFile("../../contracts/scenarios/b0-1-rate-limit.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Revision int
		Cases    []b01Case
	}
	if err = json.Unmarshal(data, &file); err != nil || file.Revision != 1 {
		t.Fatal("invalid B0.1 vectors", err)
	}
	return file.Cases
}

type admissionStub struct {
	result admissionResult
	err    error
	calls  int
	key    string
	tier   admissionTier
}

func (s *admissionStub) admit(_ context.Context, key string, tier admissionTier) (admissionResult, error) {
	s.calls++
	s.key = key
	s.tier = tier
	return s.result, s.err
}

func TestB01AdmissionRoutes(t *testing.T) {
	for _, tc := range b01Vectors(t) {
		if tc.Input.Request == "" {
			continue
		}
		t.Run(tc.ID, func(t *testing.T) {
			codec, tokens := fixture(t)
			db := &createOTPFixture{memorySessions: store()}
			sender := &createMailFixture{store: db}
			limiter := &admissionStub{result: admissionResult{false, 0, tc.Input.TTLMS}}
			if tc.Expect.Tier != "" {
				limiter.result = admissionResult{true, tc.Expect.Limit - 1, tc.Expect.WindowSeconds * 1000}
			}
			conf := RefreshConfig{Admission: limiter, otpMailer: sender, OTPSendLimiter: otpLimitFixture{fault: "limited"}}
			method, path, _ := strings.Cut(tc.Input.Request, " ")
			body := "{}"
			switch tc.ID {
			case "redis-unavailable":
				limiter.err = errors.New("offline")
			case "missing-auth", "invalid-login-input", "otp-domain-quota", "ai-domain-quota":
				limiter.result = admissionResult{true, 2, 1000}
			}
			wrapped := SessionRepository(db)
			if tc.ID == "redis-unavailable" {
				wrapped = &postListFixture{postFixture: &postFixture{memorySessions: store()}, empty: true}
			}
			if tc.ID == "ai-domain-quota" {
				model := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("unexpected model call") }))
				defer model.Close()
				conf.AIModelConfig = writingConfig(model.URL)
				conf.AIModelQuotaLimiter = &visionQuotaFixture{retry: tc.Input.DomainRetrySeconds}
				wrapped = &writingFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, latest: 4, purpose: "writing"}
				path = strings.Replace(path, "/c1/", "/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/", 1)
			}
			if tc.ID == "invalid-login-input" {
				s, _, _ := newLoginFixture(t)
				wrapped = s
			}
			if tc.ID == "otp-domain-quota" {
				body = `{"account":"fake@example.test","type":"register"}`
			}
			h := NewHandlerWithConfig(codec, wrapped, CorsPolicy{Origins: []string{"https://app.test"}}, conf)
			req := httptest.NewRequest(method, path, strings.NewReader(body))
			if tc.ID == "ai-domain-quota" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			req.Header.Set("Origin", "https://app.test")
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Accept", "application/json")
			req.RemoteAddr = "[::ffff:192.0.2.8]:443"
			req.Header.Set("X-Forwarded-For", "192.0.2.9")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if tc.ID == "retired-before-admission" {
				if limiter.calls != 0 || w.Code != tc.Expect.Status {
					t.Fatal(w.Code, limiter.calls)
				}
				return
			}
			if limiter.calls != 1 || limiter.key != "neko:v2:admission:1:"+limiter.tier.name+":192.0.2.8" {
				t.Fatal(limiter.key, limiter.calls)
			}
			if tc.Expect.Tier != "" && limiter.tier != (admissionTier{tc.Expect.Tier, tc.Expect.Limit, tc.Expect.WindowSeconds}) {
				t.Fatal(limiter.tier)
			}
			if tc.Expect.Status != 0 && w.Code != tc.Expect.Status {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			if tc.ID == "redis-unavailable" && (w.Code != 200 || w.Header().Get("RateLimit-Limit") != "") {
				t.Fatal("failed-open dispatch", w.Code)
			}
			for key, val := range tc.Expect.Headers {
				if w.Header().Get(key) != strconv.FormatInt(val, 10) {
					t.Fatal(key, w.Header())
				}
			}
			switch tc.ID {
			case "tier-rejection":
				var doc map[string]json.RawMessage
				if err := json.Unmarshal(w.Body.Bytes(), &doc); err != nil || len(doc) != 6 || string(doc["error"]) != "true" || string(doc["statusCode"]) != "429" || len(doc["message"]) <= 2 || len(doc["statusMessage"]) <= 2 || len(doc["url"]) <= 2 {
					t.Fatal(w.Body.String())
				}
				var envelope map[string]json.RawMessage
				if err := json.Unmarshal(doc["data"], &envelope); err != nil || len(envelope) != 4 || string(envelope["code"]) != "42901" || len(envelope["message"]) <= 2 || string(envelope["data"]) != "null" || string(envelope["meta"]) != "null" {
					t.Fatal(w.Body.String())
				}
				for key := range tc.Expect.Headers {
					if !strings.Contains(w.Header().Get("Access-Control-Expose-Headers"), key) {
						t.Fatal(key)
					}
				}
			case "head-rejection":
				if w.Body.Len() != 0 {
					t.Fatal("unexpected HEAD body")
				}
			case "ai-domain-quota":
				if w.Header().Get("Retry-After") != strconv.FormatInt(tc.Input.DomainRetrySeconds, 10) || !strings.Contains(w.Body.String(), `"code":42901`) {
					t.Fatal(w.Header(), w.Body.String())
				}
			case "otp-domain-quota":
				if w.Header().Get("Retry-After") != "42" || !strings.Contains(w.Body.String(), `"code":42901`) {
					t.Fatal(w.Header(), w.Body.String())
				}
			}
			if db.inserts != 0 || sender.sends != 0 {
				t.Fatal("OTP side effects")
			}
		})
	}
}

func TestB01LoginVectors(t *testing.T) {
	for _, tc := range b01Vectors(t) {
		if tc.Input.PriorRegion == "" {
			continue
		}
		t.Run(tc.ID, func(t *testing.T) {
			s, _, codec := newLoginFixture(t)
			s.known = tc.Input.KnownFingerprint
			s.previousIP = "2001:db8::8"
			s.alertDelivery.Email = "owner@example.test"
			mail := &loginAlertMailFixture{sent: make(chan string, 2)}
			regions := loginRegionMap{"2001:db8::8": tc.Input.PriorRegion, "192.0.2.1": tc.Input.CurrentRegion}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{otpMailer: mail, loginRegions: regions})
			w := loginRequest(h, `{"account":"tester","password":"synthetic-password"}`)
			if w.Code != tc.Expect.Status || len(w.Result().Cookies()) != 2 || len(s.inserted) != 1 || strconv.Itoa(s.alertCount) != string(tc.Expect.EmailSchedules) {
				t.Fatal(w.Code, s.alertCount)
			}
			if s.alertCount == 1 {
				select {
				case <-mail.sent:
				case <-time.After(time.Second):
					t.Fatal("no email")
				}
			}
		})
	}
}
