package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
)

type userQueueVector struct {
	ID, Method, Path string
	Status           int
	Denied           bool
	Query            struct {
		Q, Status, Sort string
		Start           float64 `json:"start_row"`
		End             float64 `json:"end_row"`
	}
	Data []moderationQueueUser
	Meta map[string]any
}

type userQueueFixture struct {
	*dashboardFixture
	vector userQueueVector
}

func (s *userQueueFixture) ModerationUsers(_ context.Context, filters moderationUserFilters, page SessionPage, _ StorageURLPolicy) ([]moderationQueueUser, int64, error) {
	expected := s.vector.Query
	if filters != (moderationUserFilters{Status: expected.Status, Search: expected.Q, Sort: expected.Sort}) ||
		page.Start != expected.Start || page.End != expected.End {
		return nil, 0, errSessionStore
	}
	return s.vector.Data, int64(s.vector.Meta["total"].(float64)), nil
}

func TestNativeModerationUserQueue(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/moderation-user-queue.json")
	if err != nil {
		t.Fatal(err)
	}
	var shared struct{ Cases []userQueueVector }
	if err := json.Unmarshal(raw, &shared); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	repo := &userQueueFixture{dashboardFixture: &dashboardFixture{memorySessions: store()}}
	handler := NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{ModerationAdminAccounts: " Reviewer "})
	for _, vector := range shared.Cases {
		t.Run(vector.ID, func(t *testing.T) {
			repo.vector = vector
			repo.denied = vector.Denied
			req := httptest.NewRequest(vector.Method, vector.Path, nil)
			if vector.Status != 401 {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			resp := httptest.NewRecorder()
			handler.ServeHTTP(resp, req)
			if resp.Code != vector.Status || resp.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(resp.Code, resp.Body.String())
			}
			if vector.Data != nil {
				var result struct {
					Data []moderationQueueUser
					Meta map[string]any
				}
				if err := json.Unmarshal(resp.Body.Bytes(), &result); err != nil || !reflect.DeepEqual(vector.Data, result.Data) || !reflect.DeepEqual(vector.Meta, result.Meta) {
					t.Fatal(resp.Body.String())
				}
			}
		})
	}
}
