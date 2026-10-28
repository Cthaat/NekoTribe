package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type createCommentFixture struct {
	*memorySessions
	user, post                               int64
	parent                                   *int64
	content                                  string
	writeErr, noticeErr, storeErr, authorErr error
	postAuthor, parentAuthor                 int64
	stores                                   []notificationInput
	failStoreAt                              int
	push                                     bool
	created                                  int
}

func (s *createCommentFixture) CreatePostComment(_ context.Context, user, post int64, content string, parent *int64) (PostComment, error) {
	s.user, s.post, s.content, s.parent = user, post, content, parent
	s.created++
	if s.writeErr != nil {
		return PostComment{}, s.writeErr
	}
	root := int64(100)
	if parent != nil {
		root = 30
	}
	return PostComment{ID: 100, PostID: post, AuthorID: user, ParentID: parent, RootID: &root, Content: content}, nil
}
func (s *createCommentFixture) CommentNoticeContext(context.Context, int64, int64, int64) (commentNoticeContext, error) {
	if s.noticeErr != nil {
		return commentNoticeContext{}, s.noticeErr
	}
	return commentNoticeContext{ActorName: "viewer", PostAuthor: s.postAuthor, CommentExcerpt: json.RawMessage(`"comment"`), PostExcerpt: json.RawMessage(`"post"`)}, nil
}
func (s *createCommentFixture) CommentParentNotice(context.Context, int64, int64) (commentParentNotice, error) {
	return commentParentNotice{Author: s.parentAuthor, Excerpt: json.RawMessage(`"parent"`)}, nil
}
func (s *createCommentFixture) StoreCommentNotification(_ context.Context, input notificationInput) (*notificationStored, error) {
	if s.storeErr != nil {
		return nil, s.storeErr
	}
	if input.UserID == s.user {
		return nil, nil
	}
	if s.failStoreAt > 0 && len(s.stores)+1 == s.failStoreAt {
		return nil, errors.New("private later store")
	}
	s.stores = append(s.stores, input)
	return &notificationStored{ID: int64(500 + len(s.stores)), PushEnabled: s.push}, nil
}
func (s *createCommentFixture) NotificationByID(_ context.Context, _ int64, id int64) (NotificationItem, bool, error) {
	return NotificationItem{ID: id, Type: "comment"}, true, nil
}
func (s *createCommentFixture) PublicProfile(_ context.Context, viewer, target int64) (PublicUser, bool, error) {
	if s.authorErr != nil {
		return PublicUser{}, false, s.authorErr
	}
	if viewer != 42 || target != 42 {
		return PublicUser{}, false, errors.New("wrong profile scope")
	}
	return PublicUser{UserID: 42, Username: "viewer"}, true, nil
}

func TestCreateCommentRouteAndNotificationBoundaries(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, token, body                string
		writeErr, noticeErr, storeErr    error
		postAuthor, parentAuthor         int64
		push                             bool
		status, created, notices, events int
	}{
		{"unauthenticated", "", `{"content":"hi"}`, nil, nil, nil, 7, 8, true, 401, 0, 0, 0},
		{"invalid parent", tokens["access-hs256"], `{"content":"hi","parent_comment_id":"01"}`, nil, nil, nil, 7, 8, true, 400, 0, 0, 0},
		{"object parent", tokens["access-hs256"], `{"content":"hi","parent_comment_id":{}}`, nil, nil, nil, 7, 8, true, 400, 0, 0, 0},
		{"string parent", tokens["access-hs256"], `{"content":"hi","parent_comment_id":"40"}`, nil, nil, nil, 7, 8, true, 200, 1, 2, 2},
		{"empty content", tokens["access-hs256"], `{"content":"  "}`, nil, nil, nil, 7, 8, true, 400, 0, 0, 0},
		{"hidden post", tokens["access-hs256"], `{"content":"hi"}`, errCommentPostUnavailable, nil, nil, 7, 8, true, 404, 1, 0, 0},
		{"missing parent", tokens["access-hs256"], `{"content":"hi","parent_comment_id":40}`, errCommentParentUnavailable, nil, nil, 7, 8, true, 404, 1, 0, 0},
		{"root", tokens["access-hs256"], `{"content":" hello "}`, nil, nil, nil, 7, 8, true, 200, 1, 1, 1},
		{"reply", tokens["access-hs256"], `{"content":" hello ","parent_comment_id":40}`, nil, nil, nil, 7, 8, true, 200, 1, 2, 2},
		{"deduplicate", tokens["access-hs256"], `{"content":"hi","parent_comment_id":40}`, nil, nil, nil, 7, 7, true, 200, 1, 1, 1},
		{"self", tokens["access-hs256"], `{"content":"hi","parent_comment_id":40}`, nil, nil, nil, 42, 42, true, 200, 1, 0, 0},
		{"push disabled", tokens["access-hs256"], `{"content":"hi"}`, nil, nil, nil, 7, 8, false, 200, 1, 1, 0},
		{"notice error after insert", tokens["access-hs256"], `{"content":"hi"}`, nil, errors.New("private notice"), nil, 7, 8, true, 500, 1, 0, 0},
		{"store error after insert", tokens["access-hs256"], `{"content":"hi"}`, nil, nil, errors.New("private store"), 7, 8, true, 500, 1, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &createCommentFixture{memorySessions: store(), writeErr: tc.writeErr, noticeErr: tc.noticeErr, storeErr: tc.storeErr, postAuthor: tc.postAuthor, parentAuthor: tc.parentAuthor, push: tc.push}
			pub := &likePublisher{}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: pub})
			r := httptest.NewRequest("POST", "/api/v2/posts/1/comments?user_id=99", strings.NewReader(tc.body))
			r.Header.Set("Content-Type", "application/json")
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status || s.created != tc.created || len(s.stores) != tc.notices || pub.calls != tc.events || strings.Contains(w.Body.String(), "private ") {
				t.Fatalf("status=%d created=%d notices=%d events=%d body=%s", w.Code, s.created, len(s.stores), pub.calls, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(w.Header())
			}
			if tc.created > 0 && (s.user != 42 || s.post != 1) {
				t.Fatal(s.user, s.post)
			}
			if tc.status == 200 {
				var body struct {
					Message string      `json:"message"`
					Data    PostComment `json:"data"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || body.Message != "comment created" || body.Data.Author.UserID != 42 || !body.Data.Viewer.CanDelete || body.Data.Viewer.Liked {
					t.Fatal(body, err)
				}
				if tc.name == "root" && s.content != "hello" {
					t.Fatal(s.content)
				}
				for i, n := range s.stores {
					var meta map[string]any
					if json.Unmarshal([]byte(n.MetadataJSON), &meta) != nil || n.Type != "comment" || meta["post_id"] != float64(1) || meta["comment_id"] != float64(100) {
						t.Fatal(n, meta)
					}
					if i == 0 && meta["event"] != "comment_created" {
						t.Fatal(meta)
					}
					if i == 1 && meta["event"] != "comment_reply" {
						t.Fatal(meta)
					}
					if meta["comment_excerpt"] != "comment" || meta["post_excerpt"] != "post" {
						t.Fatal(meta)
					}
					if i == 1 && (meta["parent_comment_excerpt"] != "parent" || meta["parent_comment_id"] != float64(40)) {
						t.Fatal(meta)
					}
				}
			}
		})
	}
}

func TestCreateCommentRedisFailureDoesNotUndoComment(t *testing.T) {
	codec, tokens := fixture(t)
	s := &createCommentFixture{memorySessions: store(), postAuthor: 7, push: true}
	pub := &likePublisher{fail: true}
	r := httptest.NewRequest("POST", "/api/v2/posts/1/comments", strings.NewReader(`{"content":"hi"}`))
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: pub}).ServeHTTP(w, r)
	if w.Code != 200 || s.created != 1 || len(s.stores) != 1 || pub.calls != 1 {
		t.Fatal(w.Code, s.created, len(s.stores), pub.calls)
	}
}

func TestCreateCommentLaterNotificationFailureKeepsEarlierDelivery(t *testing.T) {
	codec, tokens := fixture(t)
	s := &createCommentFixture{memorySessions: store(), postAuthor: 7, parentAuthor: 8, push: true, failStoreAt: 2}
	pub := &likePublisher{}
	r := httptest.NewRequest("POST", "/api/v2/posts/1/comments", strings.NewReader(`{"content":"hi","parent_comment_id":40}`))
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: pub}).ServeHTTP(w, r)
	if w.Code != 500 || s.created != 1 || len(s.stores) != 1 || pub.calls != 1 || strings.Contains(w.Body.String(), "private") {
		t.Fatal(w.Code, s.created, len(s.stores), pub.calls, w.Body.String())
	}
}
