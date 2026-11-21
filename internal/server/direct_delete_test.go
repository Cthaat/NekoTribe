package server

import (
	"context"
	"net/http/httptest"
	"testing"
)

type directDeleteFixture struct {
	*memorySessions
	args      [3]int64
	published [4]int64
	err       error
}

func (s *directDeleteFixture) PublishDirect(context.Context, int64, int64, DirectMessage) error {
	return nil
}

func (s *directDeleteFixture) PublishDirectDeleted(_ context.Context, actor, recipient, conversation, message int64) error {
	s.published = [4]int64{actor, recipient, conversation, message}
	return nil
}

func (s *directDeleteFixture) DeleteDirectMessage(_ context.Context, actor, conversation, message int64) (int64, error) {
	s.args = [3]int64{actor, conversation, message}
	return 9, s.err
}

func TestDirectMessageDeleteChecksSessionIDsAndStoreOutcome(t *testing.T) {
	codec, tokens := fixture(t)
	const base = "/api/v2/chat/direct-conversations/"
	for _, tc := range []struct {
		path   string
		auth   bool
		err    error
		status int
		calls  bool
	}{
		{"7/messages/9", false, nil, 401, false},
		{"7/messages/09", true, nil, 400, false},
		{"07/messages/9", true, nil, 400, false},
		{"7/messages/9", true, errDirectConversationForbidden, 403, true},
		{"7/messages/9", true, errDirectDeleteForbidden, 403, true},
		{"7/messages/9", true, errDirectMessageMissing, 404, true},
		{"7/messages/9", true, errSessionStore, 500, true},
		{"7/messages/9", true, nil, 200, true},
	} {
		repository := &directDeleteFixture{memorySessions: store(), err: tc.err}
		request := httptest.NewRequest("DELETE", base+tc.path, nil)
		if tc.auth {
			request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		response := httptest.NewRecorder()
		NewHandlerWithConfig(codec, repository, CorsPolicy{}, RefreshConfig{DirectEvents: repository}).ServeHTTP(response, request)
		want := [3]int64{}
		if tc.calls {
			want = [3]int64{42, 7, 9}
		}
		if response.Code != tc.status || repository.args != want {
			t.Fatalf("%s: status=%d args=%v, want %d %v", tc.path, response.Code, repository.args, tc.status, want)
		}
		published := [4]int64{}
		if tc.status == 200 {
			published = [4]int64{42, 9, 7, 9}
		}
		if repository.published != published {
			t.Fatalf("published %v, want %v", repository.published, published)
		}
	}
}
