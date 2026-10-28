package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type likeFixture struct {
	*memorySessions
	inserted, visible, fail, push, notify, missing bool
	prepareFail, lookupFail, profileFail           bool
	viewer, post, recipient                        int64
	prepareCalls, lookupCalls                      int
}

func (s *likeFixture) AddPostLike(_ context.Context, viewer, post int64) (float64, bool, bool, error) {
	s.viewer, s.post = viewer, post
	if s.fail {
		return 0, false, false, errors.New("private db error")
	}
	return 3, s.inserted, s.visible, nil
}
func (s *likeFixture) PreparePostLikeNotification(_ context.Context, viewer, post int64) (int64, *notificationStored, error) {
	s.prepareCalls++
	if s.prepareFail {
		return 0, nil, errors.New("private notification storage error")
	}
	if viewer != 42 || post != 1 {
		return 0, nil, errors.New("wrong viewer")
	}
	if !s.notify {
		return 0, nil, nil
	}
	return s.recipient, &notificationStored{ID: 12, PushEnabled: s.push}, nil
}
func (s *likeFixture) NotificationByID(_ context.Context, user, id int64) (NotificationItem, bool, error) {
	s.lookupCalls++
	if s.lookupFail {
		return NotificationItem{}, false, errors.New("private lookup error")
	}
	if user != s.recipient || id != 12 {
		return NotificationItem{}, false, errors.New("wrong recipient")
	}
	actor := int64(42)
	return NotificationItem{ID: 12, ActorID: &actor, Type: "like", Metadata: map[string]any{"event": "post_like"}}, !s.missing, nil
}
func (s *likeFixture) PublicProfile(_ context.Context, viewer, target int64) (PublicUser, bool, error) {
	if s.profileFail {
		return PublicUser{}, false, errors.New("private profile error")
	}
	if viewer != s.recipient || target != 42 {
		return PublicUser{}, false, errors.New("wrong profile")
	}
	return PublicUser{UserID: 42, Username: "actor"}, true, nil
}

func TestLikePostCommitFailuresReturnSafeErrorWithoutPublishing(t *testing.T) {
	codec, tokens := fixture(t)
	for _, stage := range []string{"prepare", "lookup", "profile"} {
		t.Run(stage, func(t *testing.T) {
			s := &likeFixture{memorySessions: store(), inserted: true, visible: true, notify: true, push: true, recipient: 9}
			s.prepareFail = stage == "prepare"
			s.lookupFail = stage == "lookup"
			s.profileFail = stage == "profile"
			publisher := &likePublisher{}
			handler := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: publisher})
			request := httptest.NewRequest("POST", "/api/v2/posts/1/likes", nil)
			request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != 500 || strings.Contains(response.Body.String(), "private") || publisher.calls != 0 || s.viewer != 42 {
				t.Fatal(response.Code, response.Body.String(), publisher.calls)
			}
		})
	}
}

type likePublisher struct {
	calls int
	user  int64
	kind  string
	data  map[string]interface{}
	fail  bool
}

func (p *likePublisher) Publish(_ context.Context, user int64, kind string, data map[string]interface{}) error {
	p.calls++
	p.user = user
	p.kind = kind
	p.data = data
	if p.fail {
		return errors.New("private redis error")
	}
	return nil
}

func TestLikeRouteAuthenticationAndNotificationDelivery(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, path, token                                             string
		inserted, visible, notify, push, fail, missing, publisherFail bool
		status, prepares, publishes, lookups                          int
	}{
		{"unauthorized", "/api/v2/posts/1/likes", "", true, true, true, true, false, false, false, 401, 0, 0, 0},
		{"invalid id", "/api/v2/posts/01/likes", tokens["access-hs256"], true, true, true, true, false, false, false, 400, 0, 0, 0},
		{"hidden", "/api/v2/posts/1/likes", tokens["access-hs256"], false, false, false, false, false, false, false, 404, 0, 0, 0},
		{"database error", "/api/v2/posts/1/likes", tokens["access-hs256"], false, false, false, false, true, false, false, 500, 0, 0, 0},
		{"duplicate", "/api/v2/posts/1/likes?user_id=99", tokens["access-hs256"], false, true, true, true, false, false, false, 200, 0, 0, 0},
		{"self or preference disabled", "/api/v2/posts/1/likes", tokens["access-hs256"], true, true, false, false, false, false, false, 200, 1, 0, 0},
		{"push disabled", "/api/v2/posts/1/likes", tokens["access-hs256"], true, true, true, false, false, false, false, 200, 1, 0, 1},
		{"missing mapped notification", "/api/v2/posts/1/likes", tokens["access-hs256"], true, true, true, true, false, true, false, 200, 1, 0, 1},
		{"delivered", "/api/v2/posts/1/likes", tokens["access-hs256"], true, true, true, true, false, false, false, 200, 1, 1, 1},
		{"redis failure", "/api/v2/posts/1/likes", tokens["access-hs256"], true, true, true, true, false, false, true, 200, 1, 1, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &likeFixture{memorySessions: store(), inserted: tc.inserted, visible: tc.visible, notify: tc.notify, push: tc.push, fail: tc.fail, missing: tc.missing, recipient: 9}
			pub := &likePublisher{fail: tc.publisherFail}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: pub})
			r := httptest.NewRequest("POST", tc.path, nil)
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status || strings.Contains(w.Body.String(), "private") {
				t.Fatalf("%d %s", w.Code, w.Body.String())
			}
			if s.prepareCalls != tc.prepares || s.lookupCalls != tc.lookups || pub.calls != tc.publishes {
				t.Fatalf("prepare=%d lookup=%d publish=%d", s.prepareCalls, s.lookupCalls, pub.calls)
			}
			if tc.status == 200 {
				var out struct {
					Data struct {
						PostID int64   `json:"post_id"`
						Liked  bool    `json:"is_liked"`
						Count  float64 `json:"likes_count"`
					} `json:"data"`
				}
				if json.Unmarshal(w.Body.Bytes(), &out) != nil || out.Data.PostID != 1 || !out.Data.Liked || out.Data.Count != 3 || s.viewer != 42 {
					t.Fatal(w.Body.String())
				}
			}
			if pub.calls > 0 {
				item, ok := pub.data["notification"].(NotificationItem)
				if !ok || pub.user != 9 || pub.kind != "notification_created" || pub.data["notification_type"] != "like" || item.Actor == nil || item.Actor.UserID != 42 {
					t.Fatal(pub)
				}
			}
		})
	}
}
