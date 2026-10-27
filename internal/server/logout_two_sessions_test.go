package server

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

// The two accounts share one isolated store, like sessions in the same database.
type twoAccountSessions struct {
	*memorySessions
	refreshHashes map[string]string
}

func (s *twoAccountSessions) RevokeRefresh(_ context.Context, claims auth.Claims, hash string) (int64, error) {
	for i := range s.rows {
		row := &s.rows[i]
		if row.user == claims.UserID && row.id == claims.SessionID && !row.revoked && s.refreshHashes[row.id] == hash {
			row.revoked = true
			return 1, nil
		}
	}
	return 0, nil
}

func (s *twoAccountSessions) RevokeAccess(_ context.Context, claims auth.Claims) (int64, error) {
	for i := range s.rows {
		row := &s.rows[i]
		if row.user == claims.UserID && row.id == claims.SessionID && !row.revoked && row.jti == claims.JTI {
			row.revoked = true
			return 1, nil
		}
	}
	return 0, nil
}

func TestLogoutRefreshSelectsOneOfTwoAccounts(t *testing.T) {
	codec, tokens := fixture(t)
	otherAccess, err := codec.Sign(auth.Claims{UserID: 99, SessionID: "account-b", JTI: "account-b-jti", Kind: auth.Access}, 900)
	if err != nil {
		t.Fatal(err)
	}
	store := &twoAccountSessions{
		memorySessions: &memorySessions{rows: []session{
			{user: 42, id: "fixture-session-42", jti: "fixture-access-jti-42"},
			{user: 99, id: "account-b", jti: "account-b-jti"},
		}},
		refreshHashes: map[string]string{
			"fixture-session-42": refreshHash(tokens["refresh-hs256"]),
			"account-b":          "other-refresh-hash",
		},
	}
	handler := NewHandler(codec, store, CorsPolicy{})
	body := fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])
	response := logoutRequest(handler, body, "access_token="+otherAccess, "", "application/json")
	if response.Code != http.StatusOK || !store.rows[0].revoked || store.rows[1].revoked {
		t.Fatalf("logout status=%d, selected revoked=%v, other revoked=%v", response.Code, store.rows[0].revoked, store.rows[1].revoked)
	}
	protected := func(token string) int {
		req := httptest.NewRequest(http.MethodDelete, "/api/v2/auth/sessions/others", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out.Code
	}
	if status := protected(otherAccess); status != http.StatusOK || store.rows[1].revoked {
		t.Fatalf("unselected account lost access: status=%d", status)
	}
	if status := protected(tokens["access-hs256"]); status != http.StatusUnauthorized {
		t.Fatalf("logged-out account kept access: status=%d", status)
	}
}
