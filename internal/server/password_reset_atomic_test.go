package server

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

// This store models an indivisible database transaction.
type atomicResetFixture struct {
	*resetFixture
	mu              sync.Mutex
	consumed        bool
	activeSessions  int
	failTransaction bool
}

func (s *atomicResetFixture) FindOTP(_ context.Context, email, kind, id string) (string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.otpHash, !s.consumed && email == "fake@example.test" && kind == "password_reset" && id == "otp_fixture", nil
}

func (s *atomicResetFixture) ResetPasswordAtomic(_ context.Context, email, id, oldOTPHash, newPasswordHash string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failTransaction {
		return 0, errors.New("synthetic-transaction-failure")
	}
	if s.consumed || email != "fake@example.test" || id != "otp_fixture" || oldOTPHash != s.otpHash {
		return 1, nil
	}
	if s.missing {
		return 2, nil
	}
	s.consumed = true
	s.activeSessions = 0
	s.passwordHash = newPasswordHash
	return 0, nil
}

func TestPasswordResetConsumesOTPAndRevokesSessions(t *testing.T) {
	hash, err := bcrypt.GenerateFromPassword([]byte("123456"), 4)
	if err != nil {
		t.Fatal(err)
	}
	codec, _ := fixture(t)
	s := &atomicResetFixture{resetFixture: &resetFixture{memorySessions: store(), otpHash: string(hash)}, activeSessions: 2}
	h := NewHandler(codec, s, CorsPolicy{})
	post := func() int {
		req := httptest.NewRequest("POST", "/api/v2/auth/password-reset", strings.NewReader(`{"email":"fake@example.test","verification_id":"otp_fixture","code":"123456","new_password":"synthetic-new-password"}`))
		req.Header.Set("Content-Type", "application/json")
		res := httptest.NewRecorder()
		h.ServeHTTP(res, req)
		return res.Code
	}
	if got := post(); got != 200 {
		t.Fatalf("first reset status %d", got)
	}
	if !s.consumed || s.activeSessions != 0 || !matchesLoginPassword(s.passwordHash, "synthetic-new-password") {
		t.Fatal("reset did not atomically consume OTP and revoke existing sessions")
	}
	if got := post(); got != 400 {
		t.Fatalf("replayed reset status %d", got)
	}
}

func TestPasswordResetRollsBackOnTransactionFailure(t *testing.T) {
	hash, _ := bcrypt.GenerateFromPassword([]byte("123456"), 4)
	codec, _ := fixture(t)
	s := &atomicResetFixture{resetFixture: &resetFixture{memorySessions: store(), otpHash: string(hash)}, activeSessions: 2, failTransaction: true}
	req := httptest.NewRequest("POST", "/api/v2/auth/password-reset", strings.NewReader(`{"email":"fake@example.test","verification_id":"otp_fixture","code":"123456","new_password":"synthetic-new-password"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()
	NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
	if res.Code != 500 || s.consumed || s.activeSessions != 2 || s.passwordHash != "" {
		t.Fatal("failed transaction changed account state")
	}
}

func TestConcurrentPasswordResetAllowsOnlyOneCommit(t *testing.T) {
	hash, _ := bcrypt.GenerateFromPassword([]byte("123456"), 4)
	codec, _ := fixture(t)
	s := &atomicResetFixture{resetFixture: &resetFixture{memorySessions: store(), otpHash: string(hash)}, activeSessions: 2}
	h := NewHandler(codec, s, CorsPolicy{})
	start := make(chan struct{})
	statuses := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func() {
			<-start
			req := httptest.NewRequest("POST", "/api/v2/auth/password-reset", strings.NewReader(`{"email":"fake@example.test","verification_id":"otp_fixture","code":"123456","new_password":"synthetic-new-password"}`))
			req.Header.Set("Content-Type", "application/json")
			res := httptest.NewRecorder()
			h.ServeHTTP(res, req)
			statuses <- res.Code
		}()
	}
	close(start)
	a, b := <-statuses, <-statuses
	if !((a == 200 && b == 400) || (a == 400 && b == 200)) {
		t.Fatalf("unexpected concurrent statuses: %d %d", a, b)
	}
}
