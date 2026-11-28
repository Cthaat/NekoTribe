package server

import (
	"context"
	"fmt"
	"golang.org/x/crypto/bcrypt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

type challengeRace struct {
	*factorFixture
	mu      sync.Mutex
	arrived chan struct{}
	release chan struct{}
}

func (s *challengeRace) InsertLoginSession(ctx context.Context, session LoginSession) (loginHistory, error) {
	s.arrived <- struct{}{}
	<-s.release
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.factorFixture.InsertLoginSession(ctx, session)
}

type recoveryRace struct {
	*factorFixture
	mu          sync.Mutex
	arrived     chan struct{}
	release     chan struct{}
	consumedIDs map[string]bool
}

func (s *recoveryRace) FindLoginChallenge(_ context.Context, id string) (LoginChallenge, bool, error) {
	c := s.challenge
	c.ID = id
	return c, true, nil
}
func (s *recoveryRace) FindRecoveryCodes(context.Context, int64) ([]RecoveryCode, error) {
	return s.codes, nil
}
func (s *recoveryRace) InsertLoginSession(ctx context.Context, session LoginSession) (loginHistory, error) {
	s.arrived <- struct{}{}
	<-s.release
	s.mu.Lock()
	defer s.mu.Unlock()
	id := session.factorCompletion.challenge.ID
	if s.recoveryUsed || s.consumedIDs[id] {
		return loginHistory{}, errFactorCompletionUnavailable
	}
	history, err := s.loginFixtureStore.InsertLoginSession(ctx, session)
	if err != nil {
		return loginHistory{}, err
	}
	s.recoveryUsed = true
	s.consumedIDs[id] = true
	return history, nil
}
func runFactorRace(t *testing.T, h http.Handler, bodies []string, arrived chan struct{}, release chan struct{}) []*httptest.ResponseRecorder {
	t.Helper()
	results := make([]*httptest.ResponseRecorder, len(bodies))
	var wg sync.WaitGroup
	for i, body := range bodies {
		wg.Add(1)
		go func(i int, body string) { defer wg.Done(); results[i] = factorRequest(h, body) }(i, body)
	}
	for range bodies {
		select {
		case <-arrived:
		case <-time.After(3 * time.Second):
			close(release)
			wg.Wait()
			t.Fatal("requests did not both reach consumption barrier")
		}
	}
	close(release)
	wg.Wait()
	return results
}
func assertOneFactorSuccess(t *testing.T, results []*httptest.ResponseRecorder, s *loginFixtureStore) {
	t.Helper()
	success, failure := 0, 0
	for _, w := range results {
		switch w.Code {
		case 200:
			success++
			if len(w.Result().Cookies()) != 2 {
				t.Fatal("successful login lacks cookies")
			}
		case 401:
			failure++
			if len(w.Result().Cookies()) != 0 {
				t.Fatal("failed login sent cookies")
			}
		default:
			t.Fatalf("unexpected status %d %s", w.Code, w.Body.String())
		}
	}
	if success != 1 || failure != 1 || len(s.inserted) != 1 {
		t.Fatalf("success=%d failure=%d sessions=%d", success, failure, len(s.inserted))
	}
}
func TestConcurrentSameChallengeCreatesOneSession(t *testing.T) {
	base, _, codec := newLoginFixture(t)
	base.twoFactor = true
	factor := &factorFixture{loginFixtureStore: base, factor: factorSecretForTest(t, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"), challenge: LoginChallenge{ID: "2fa-test", UserID: 42, Username: "tester"}}
	race := &challengeRace{factorFixture: factor, arrived: make(chan struct{}, 2), release: make(chan struct{})}
	h := NewHandlerWithConfig(codec, race, CorsPolicy{}, RefreshConfig{AccessSeconds: 900, RefreshSeconds: 3600, clock: func() time.Time { return time.Unix(59, 0) }})
	body := `{"challenge_id":"2fa-test","code":"287082"}`
	assertOneFactorSuccess(t, runFactorRace(t, h, []string{body, body}, race.arrived, race.release), base)
}
func TestConcurrentRecoveryAcrossChallengesCreatesOneSession(t *testing.T) {
	base, _, codec := newLoginFixture(t)
	base.twoFactor = true
	hash, err := bcrypt.GenerateFromPassword([]byte("ABCDE12345"), 4)
	if err != nil {
		t.Fatal(err)
	}
	factor := &factorFixture{loginFixtureStore: base, factor: factorSecretForTest(t, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"), challenge: LoginChallenge{UserID: 42, Username: "tester"}, codes: []RecoveryCode{{ID: 1, Hash: string(hash)}}}
	race := &recoveryRace{factorFixture: factor, arrived: make(chan struct{}, 2), release: make(chan struct{}), consumedIDs: map[string]bool{}}
	h := NewHandlerWithConfig(codec, race, CorsPolicy{}, RefreshConfig{AccessSeconds: 900, RefreshSeconds: 3600, clock: func() time.Time { return time.Unix(59, 0) }})
	bodies := []string{fmt.Sprintf(`{"challenge_id":%q,"code":"abcde-12345"}`, "2fa-a"), fmt.Sprintf(`{"challenge_id":%q,"code":"abcde-12345"}`, "2fa-b")}
	assertOneFactorSuccess(t, runFactorRace(t, h, bodies, race.arrived, race.release), base)
}
