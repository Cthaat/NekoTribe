package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

type postFixture struct {
	*memorySessions
	post    PostDetail
	events  []string
	fault   string
	missing bool
	viewer  *int64
}

func (s *postFixture) mark(stage string) error {
	s.events = append(s.events, stage)
	if s.fault == stage {
		return errors.New("private-database-error")
	}
	return nil
}
func (s *postFixture) ReadVisiblePost(_ context.Context, viewer *int64, id int64) (PostDetail, bool, error) {
	s.viewer = viewer
	err := s.mark("post")
	if id != 1 {
		return PostDetail{}, false, errors.New("wrong id")
	}
	return s.post, !s.missing, err
}
func (s *postFixture) ReadPostAuthor(_ context.Context, viewer *int64, id int64) (PublicUser, bool, error) {
	err := s.mark("author")
	if id != 7 {
		return PublicUser{}, false, errors.New("wrong author")
	}
	return s.post.Author, s.fault != "author-missing", err
}
func (s *postFixture) CheckMediaSchema(context.Context) error { return s.mark("media-ready") }
func (s *postFixture) ReadPostMedia(_ context.Context, id int64) ([]PostMedia, error) {
	return s.post.Media, s.mark("media")
}
func (s *postFixture) ReadPostTags(_ context.Context, id int64) ([]string, error) {
	return s.post.Tags, s.mark("tags")
}
func (s *postFixture) ReadPostMentions(_ context.Context, viewer *int64, id int64) ([]PublicUser, error) {
	return s.post.Mentions, s.mark("mentions")
}
func (s *postFixture) IncrementPostViews(_ context.Context, id int64) error { return s.mark("views") }
func TestSharedPostDetailVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/post-detail-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Post  PostDetail
		Cases []struct {
			ID, Auth, Target, Fault string
			Status                  int
			Events                  []string
			Missing, Revoked        bool
			TouchFail               bool `json:"touch_fail"`
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil || len(f.Cases) != 22 {
		t.Fatal("bad fixture", err)
	}
	codec, tokens := fixture(t)
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &postFixture{memorySessions: store(), post: f.Post, fault: tc.Fault, missing: tc.Missing, events: []string{}}
			s.rows[0].revoked = tc.Revoked
			s.touchErr = tc.TouchFail
			req := httptest.NewRequest("GET", "/api/v2/posts/"+tc.Target+"?viewer_id=99", nil)
			switch tc.Auth {
			case "valid":
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "cookie":
				req.Header.Set("Cookie", "access_token="+tokens["access-hs256"])
			case "bad-cookie":
				req.Header.Set("Cookie", "access_token=bad")
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			case "expired":
				req.Header.Set("Authorization", "Bearer "+tokens["expired"])
			}
			res := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(res, req)
			if res.Code != tc.Status || !reflect.DeepEqual(s.events, tc.Events) {
				t.Fatalf("status=%d events=%v body=%s", res.Code, s.events, res.Body.String())
			}
			if strings.Contains(res.Body.String(), "private-database-error") {
				t.Fatal("private error leaked")
			}
			if tc.Status == 200 {
				var out struct{ Data PostDetail }
				if err := json.Unmarshal(res.Body.Bytes(), &out); err != nil || !reflect.DeepEqual(out.Data, f.Post) {
					t.Fatalf("incorrect response %s %v", res.Body.String(), err)
				}
				if res.Header().Get("Cache-Control") != "private, no-store" {
					t.Fatal("cache not disabled")
				}
			}
			if len(tc.Events) > 0 {
				if tc.Auth == "none" && s.viewer != nil {
					t.Fatal("anonymous viewer must be NULL")
				}
				if tc.Auth != "none" && (s.viewer == nil || *s.viewer != 42) {
					t.Fatal("viewer not authenticated")
				}
			}
		})
	}
}
func TestNormalizePrivatePostMediaKeepsCanonicalContentURL(t *testing.T) {
	policy := StorageURLPolicy{PublicBase: "/api/v2/media", CDNBaseURL: "https://example.test"}
	media := PostMedia{MediaID: 77, PublicURL: "/api/v2/media/77/content"}
	if err := normalizePostMedia(policy, &media); err != nil || media.PublicURL != "/api/v2/media/77/content" {
		t.Fatal(media, err)
	}
}
