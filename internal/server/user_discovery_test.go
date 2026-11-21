package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
)

type discoveryFixture struct {
	*memorySessions
	viewer int64
	query  userSearch
	limit  float64
}

func (s *discoveryFixture) SearchUsers(_ context.Context, viewer int64, query userSearch) ([]PublicUser, int64, error) {
	s.viewer, s.query = viewer, query
	if query.page.Start > 8 {
		return nil, 8, nil
	}
	return []PublicUser{{UserID: 7}}, 8, nil
}

func (s *discoveryFixture) RecommendUsers(_ context.Context, viewer int64, limit float64) ([]PublicUser, error) {
	s.viewer, s.limit = viewer, limit
	return []PublicUser{{UserID: 7}}, nil
}

func TestUserDiscoveryRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/user-discovery.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID, Path, Pattern, Sort string
			Verified, Status        int
			Empty                   bool
			Meta                    map[string]any
		}
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, vector := range vectors.Cases {
		t.Run(vector.ID, func(t *testing.T) {
			store := &discoveryFixture{memorySessions: store()}
			handler := NewHandler(codec, store, CorsPolicy{})
			req := httptest.NewRequest(http.MethodGet, vector.Path, nil)
			if vector.Status != 401 {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			handler.ServeHTTP(res, req)
			if res.Code != vector.Status {
				t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
			}
			if vector.Status != 200 {
				if store.viewer != 0 {
					t.Fatal("anonymous request reached storage")
				}
				return
			}
			var payload struct {
				Data []PublicUser
				Meta map[string]any
			}
			if err := json.Unmarshal(res.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(payload.Meta, vector.Meta) || payload.Data == nil || (len(payload.Data) == 0) != vector.Empty ||
				res.Header().Get("Cache-Control") != "private, no-store" || store.viewer != 42 {
				t.Fatal(res.Body.String())
			}
			if limit, ok := vector.Meta["limit"].(float64); ok {
				if store.limit != limit {
					t.Fatalf("limit=%v", store.limit)
				}
			} else if store.query.pattern != vector.Pattern || store.query.sort != vector.Sort || store.query.verified != vector.Verified {
				t.Fatalf("unexpected search: %+v", store.query)
			}
		})
	}
}
