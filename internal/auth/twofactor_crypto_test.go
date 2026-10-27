package auth

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

func TestSharedTwoFactorCryptoVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-twofactor-crypto.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID, RefreshSecret, Encrypted, IV, Tag string
			Expected                              *string
		}
	}
	if err = json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) != 3 {
		t.Fatal("missing shared crypto cases")
	}
	for _, tc := range fixture.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			codec, err := NewTokenManager([]byte("public-access-key"), []byte(tc.RefreshSecret), time.Now)
			if err != nil {
				t.Fatal(err)
			}
			actual, err := codec.OpenTwoFactorSecret(tc.Encrypted, tc.IV, tc.Tag)
			if tc.Expected == nil {
				if err == nil || actual != "" {
					t.Fatal("tampered ciphertext accepted")
				}
			} else if err != nil || actual != *tc.Expected {
				t.Fatal("cross-runtime ciphertext did not decode")
			}
		})
	}
}
