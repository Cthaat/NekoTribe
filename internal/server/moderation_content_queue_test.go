package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
)

type contentQueueVector struct {
	ID, Method, Path string
	Status           int
	Denied           bool
	Query            struct {
		Status, Priority, Reason, Q, Sort string
		Date                              string  `json:"date_range"`
		Start                             float64 `json:"start_row"`
		End                               float64 `json:"end_row"`
	}
	Meta map[string]any
	Item *struct {
		CaseID  int64    `json:"case_id"`
		PostID  int64    `json:"post_id"`
		Reasons []string `json:"report_reasons"`
		Reports []int64  `json:"report_ids"`
		Media   []int64  `json:"media_ids"`
	}
}

type contentQueueFixture struct {
	*dashboardFixture
	vector contentQueueVector
}

func (s *contentQueueFixture) ModerationContent(_ context.Context, viewer int64, f contentQueueFilters, page SessionPage, _ StorageURLPolicy) ([]contentQueueItem, int64, error) {
	q := s.vector.Query
	if viewer != 42 || f != (contentQueueFilters{Status: q.Status, Priority: q.Priority, Reason: q.Reason, Search: q.Q, Date: q.Date, Sort: q.Sort}) || page.Start != q.Start || page.End != q.End {
		return nil, 0, errSessionStore
	}
	items := []contentQueueItem{}
	if v := s.vector.Item; v != nil {
		item := contentQueueItem{CaseID: v.CaseID, PostID: v.PostID, Reasons: v.Reasons}
		for _, id := range v.Reports {
			item.Reports = append(item.Reports, moderationReport{ID: id})
		}
		for _, id := range v.Media {
			item.Media = append(item.Media, PostMedia{MediaID: id})
		}
		items = append(items, item)
	}
	return items, int64(s.vector.Meta["total"].(float64)), nil
}

func TestNativeModerationContentQueue(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/moderation-content-queue.json")
	if err != nil {
		t.Fatal(err)
	}
	var shared struct{ Cases []contentQueueVector }
	if err := json.Unmarshal(raw, &shared); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	repo := &contentQueueFixture{dashboardFixture: &dashboardFixture{memorySessions: store()}}
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
			if vector.Meta != nil {
				var result struct {
					Data []contentQueueItem
					Meta map[string]any
				}
				if err := json.Unmarshal(resp.Body.Bytes(), &result); err != nil || !reflect.DeepEqual(result.Meta, vector.Meta) {
					t.Fatal(resp.Body.String())
				}
				if v := vector.Item; v != nil {
					if len(result.Data) != 1 {
						t.Fatal(resp.Body.String())
					}
					item := result.Data[0]
					if item.CaseID != v.CaseID || item.PostID != v.PostID || !reflect.DeepEqual(item.Reasons, v.Reasons) ||
						len(item.Reports) != len(v.Reports) || len(item.Media) != len(v.Media) {
						t.Fatal(resp.Body.String())
					}
					for i, r := range item.Reports {
						if r.ID != v.Reports[i] {
							t.Fatal(resp.Body.String())
						}
					}
					for i, m := range item.Media {
						if m.MediaID != v.Media[i] {
							t.Fatal(resp.Body.String())
						}
					}
				} else if result.Data == nil || len(result.Data) != 0 {
					t.Fatal(resp.Body.String())
				}
			}
		})
	}
}
