package auth

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

type vectors struct {
	Now  int64 `json:"now"`
	Keys struct {
		Access  string `json:"access"`
		Refresh string `json:"refresh"`
	} `json:"keys"`
	Cases []struct {
		ID                       string `json:"id"`
		Type                     Kind   `json:"type"`
		Token                    string `json:"token"`
		ExpectedValid            bool   `json:"expectedValid"`
		ExpectedValidForRotation *bool  `json:"expectedValidForRotation"`
		ExpectedUserID           int64  `json:"expectedUserId"`
	} `json:"cases"`
}

func TestNuxtTokenVectors(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/auth-tokens.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture vectors
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) != 35 {
		t.Fatalf("expected 35 common vectors, got %d", len(fixture.Cases))
	}
	manager, err := NewTokenManager([]byte(fixture.Keys.Access), []byte(fixture.Keys.Refresh), func() time.Time { return time.Unix(fixture.Now, 0) })
	if err != nil {
		t.Fatal(err)
	}
	for _, vector := range fixture.Cases {
		t.Run(vector.ID, func(t *testing.T) {
			if vector.Type == Refresh {
				expected := vector.ExpectedValid
				if vector.ExpectedValidForRotation != nil {
					expected = *vector.ExpectedValidForRotation
				}
				claims, err := manager.VerifyRefreshForRotation(vector.Token)
				if expected {
					if err != nil || claims.UserID != vector.ExpectedUserID || claims.SessionID != "fixture-session-42" {
						t.Fatalf("unexpected rotation claims: %+v, %v", claims, err)
					}
				} else if !errors.Is(err, ErrInvalidToken) {
					t.Fatalf("expected sanitized rotation rejection, got %v", err)
				}
			}
			claims, err := manager.Verify(vector.Token, vector.Type)
			if !vector.ExpectedValid {
				if !errors.Is(err, ErrInvalidToken) {
					t.Fatalf("expected sanitized invalid token error, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if claims.UserID != vector.ExpectedUserID || claims.Kind != vector.Type || claims.SessionID != "fixture-session-42" {
				t.Fatalf("unexpected claims: %+v", claims)
			}
		})
	}
}

func TestIssuedTokenRoundTripAndExpiration(t *testing.T) {
	now := time.Unix(1700000000, 0)
	manager, err := NewTokenManager([]byte("fixture-access"), []byte("fixture-refresh"), func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	for _, kind := range []Kind{Access, Refresh} {
		input := Claims{UserID: 42, UserName: "测试用户", SessionID: "session", JTI: "unique-token", Kind: kind}
		token, err := manager.Sign(input, 900)
		if err != nil {
			t.Fatal(err)
		}
		actual, err := manager.Verify(token, kind)
		if err != nil || actual != input {
			t.Fatalf("round trip mismatch: %+v, %v", actual, err)
		}
		now = now.Add(900 * time.Second)
		if _, err := manager.Verify(token, kind); !errors.Is(err, ErrInvalidToken) {
			t.Fatalf("expired token accepted: %v", err)
		}
	}
}

func TestInvalidTokenConfigurationAndClaims(t *testing.T) {
	if _, err := NewTokenManager(nil, []byte("refresh"), time.Now); err == nil {
		t.Fatal("empty access key accepted")
	}
	if _, err := NewTokenManager([]byte("access"), nil, time.Now); err == nil {
		t.Fatal("empty refresh key accepted")
	}
	if _, err := NewTokenManager([]byte("access"), []byte("refresh"), nil); err == nil {
		t.Fatal("nil clock accepted")
	}
	manager, err := NewTokenManager([]byte("access"), []byte("refresh"), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	base := Claims{UserID: 1, SessionID: "session", JTI: "jti", Kind: Access}
	for _, change := range []func(*Claims){
		func(c *Claims) { c.UserID = 0 }, func(c *Claims) { c.UserID = 9007199254740992 },
		func(c *Claims) { c.SessionID = "" }, func(c *Claims) { c.JTI = "" }, func(c *Claims) { c.Kind = "other" },
	} {
		invalid := base
		change(&invalid)
		if _, err := manager.Sign(invalid, 900); !errors.Is(err, ErrInvalidClaims) {
			t.Fatalf("invalid claims accepted: %v", err)
		}
	}
	for _, ttl := range []int64{0, -1, 9223372036854775807} {
		if _, err := manager.Sign(base, ttl); !errors.Is(err, ErrInvalidClaims) {
			t.Fatalf("invalid TTL accepted: %v", err)
		}
	}
	if _, err := manager.Verify("anything", Kind("other")); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("invalid kind accepted")
	}
	for _, text := range []string{fmt.Sprint(manager), fmt.Sprintf("%+v", manager), fmt.Sprintf("%#v", manager)} {
		if strings.Contains(text, "access") || strings.Contains(text, "refresh") {
			t.Fatalf("keys exposed by formatting: %s", text)
		}
	}
}
