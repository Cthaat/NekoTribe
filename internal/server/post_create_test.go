package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"net/url"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestSharedPostCreateRequestVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/post-create-request-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	type requestInput struct {
		Content    string    `json:"content"`
		Visibility string    `json:"visibility"`
		Location   string    `json:"location"`
		MediaIDs   []float64 `json:"media_ids"`
		Tags       []string  `json:"tag_names"`
		Mentions   []float64 `json:"mention_user_ids"`
		Reply      *int64    `json:"reply_to_post_id"`
		Repost     *int64    `json:"repost_of_post_id"`
		Quote      *int64    `json:"quoted_post_id"`
	}
	var vectors struct {
		Cases []struct {
			ID, Route string
			PathID    string `json:"path_id"`
			Body      json.RawMessage
			Expected  struct {
				Status, Code int
				Message      string
				Input        requestInput
			}
		}
	}
	if err = json.Unmarshal(raw, &vectors); err != nil || len(vectors.Cases) == 0 {
		t.Fatal("empty or invalid vectors", err)
	}
	codec, tokens := fixture(t)
	for _, tc := range vectors.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := newPostCreateFixture()
			path := "/api/v2/posts"
			if tc.Route == "retweet" {
				path += "/" + tc.PathID + "/retweets"
			}
			// net/http rejects malformed escapes before routing. Exercise the raw
			// route parameter separately for this parser-boundary vector.
			_, pathErr := url.ParseRequestURI(path)
			if pathErr != nil {
				path = "/api/v2/posts/1/retweets"
			}
			r := httptest.NewRequest("POST", path, strings.NewReader(string(tc.Body)))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			if pathErr != nil {
				createPost(w, r, codec, s, RefreshConfig{}, tc.PathID)
			} else {
				NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
			}
			var out struct {
				Code    int
				Message string
			}
			if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
			if w.Code != tc.Expected.Status || out.Code != tc.Expected.Code || out.Message != tc.Expected.Message {
				t.Fatalf("status=%d body=%s expected=%+v", w.Code, w.Body.String(), tc.Expected)
			}
			if tc.Expected.Status != 200 {
				if s.created != 0 {
					t.Fatal("wrote an invalid request")
				}
				return
			}
			if s.created != 1 || s.actor != 42 {
				t.Fatal(s.created, s.actor)
			}
			in := s.input
			got := requestInput{in.Content, in.Visibility, in.Location, append([]float64{}, in.MediaIDs...), append([]string{}, in.Tags...), append([]float64{}, in.Mentions...), in.ReplyToPostID, in.RepostOfPostID, in.QuotedPostID}
			if !reflect.DeepEqual(got, tc.Expected.Input) {
				t.Fatalf("input=%+v expected=%+v", got, tc.Expected.Input)
			}
		})
	}
}

func TestCreatePostJSONNumberOverflowMatchesNuxt(t *testing.T) {
	codec, tokens := fixture(t)
	s := newPostCreateFixture()
	r := httptest.NewRequest("POST", "/api/v2/posts", strings.NewReader(`{"content":1e400,"location":-1e400,"media_ids":[1e400,-1e400,1.25],"mention_user_ids":[1e400,7.5],"tag_names":[1e400]}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
	if w.Code != 200 || s.input.Content != "Infinity" || s.input.Location != "-Infinity" || !reflect.DeepEqual(s.input.MediaIDs, []float64{1.25}) || !reflect.DeepEqual(s.input.Mentions, []float64{7.5}) || !reflect.DeepEqual(s.input.Tags, []string{"Infinity"}) {
		t.Fatal(w.Code, w.Body.String(), s.input)
	}
}

func TestReadPostCreateBodyRejectsNonObjectsAndTrailingJSON(t *testing.T) {
	for _, body := range []string{"", "null", "[]", `"text"`, "true", "1", "{", "{} {}", "{} null", strings.Repeat(" ", (1<<20)+1)} {
		r := httptest.NewRequest("POST", "/api/v2/posts", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		if _, ok := readPostCreateBody(r); ok {
			t.Fatal("accepted a non-object, invalid, or oversized body")
		}
	}
	for _, body := range []string{"", "content=hi&media_ids=1&media_ids=2"} {
		r := httptest.NewRequest("POST", "/api/v2/posts", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		parsed, ok := readPostCreateBody(r)
		if !ok {
			t.Fatal("rejected URL-encoded object")
		}
		if body != "" {
			input, message := readPostCreateInput(parsed, nil)
			if message != "" || input.Content != "hi" || !reflect.DeepEqual(input.MediaIDs, []float64{1, 2}) {
				t.Fatal(input, message)
			}
		}
	}
}

type postCreateFixture struct {
	*postFixture
	input     PostCreateInput
	actor     int64
	created   int
	writeErr  error
	noticeErr error
}

func (s *postCreateFixture) CreatePostAtomic(_ context.Context, actor int64, input PostCreateInput) (int64, error) {
	s.actor, s.input = actor, input
	s.created++
	s.events = append(s.events, "create")
	return 1, s.writeErr
}
func (s *postCreateFixture) PostCreateActorName(context.Context, int64) (string, error) {
	s.events = append(s.events, "notice")
	return "viewer", s.noticeErr
}
func (s *postCreateFixture) PostCreateSourceAuthor(context.Context, int64) (int64, error) {
	return 0, nil
}
func (s *postCreateFixture) PostCreateExcerpt(context.Context, int64) (json.RawMessage, error) {
	return json.RawMessage(`"post"`), nil
}
func (s *postCreateFixture) ResolvePostMentionRecipient(context.Context, float64) (int64, error) {
	return 0, nil
}
func (s *postCreateFixture) StorePostCreateNotification(context.Context, notificationInput) (*notificationStored, error) {
	return nil, nil
}
func (s *postCreateFixture) NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error) {
	return NotificationItem{}, false, nil
}

func newPostCreateFixture() *postCreateFixture {
	return &postCreateFixture{postFixture: &postFixture{memorySessions: store(), post: PostDetail{PostID: 1, Author: PublicUser{UserID: 7}, Media: []PostMedia{}, Tags: []string{}, Mentions: []PublicUser{}}, events: []string{}}}
}

func TestCreatePostHTTPBoundaries(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, path, body, token string
		writeErr, noticeErr     error
		fault                   string
		status, created         int
		message                 string
	}{
		{"unauthenticated", "/api/v2/posts", `{"content":"hi"}`, "", nil, nil, "", 401, 0, "请先登录"},
		{"expired", "/api/v2/posts", `{"content":"hi"}`, tokens["expired"], nil, nil, "", 401, 0, "Token无效或已过期"},
		{"invalid body", "/api/v2/posts", `[]`, tokens["access-hs256"], nil, nil, "", 400, 0, "请求体必须是 JSON 对象"},
		{"empty visibility", "/api/v2/posts", `{"content":"hi","visibility":""}`, tokens["access-hs256"], nil, nil, "", 400, 0, "visibility 参数错误"},
		{"invalid reference", "/api/v2/posts", `{"content":"hi","reply_to_post_id":"01"}`, tokens["access-hs256"], nil, nil, "", 400, 0, "id 参数错误"},
		{"multiple references", "/api/v2/posts", `{"content":"hi","reply_to_post_id":1,"quoted_post_id":2}`, tokens["access-hs256"], nil, nil, "", 400, 0, "引用字段只能传一个"},
		{"empty content", "/api/v2/posts", `{"content":" \n"}`, tokens["access-hs256"], nil, nil, "", 400, 0, "content 不能为空"},
		{"hidden source", "/api/v2/posts", `{"content":"hi","reply_to_post_id":1}`, tokens["access-hs256"], errPostReferenceUnavailable, nil, "", 404, 1, "帖子不存在"},
		{"invalid media", "/api/v2/posts", `{"media_ids":[1]}`, tokens["access-hs256"], errPostMediaUnavailable, nil, "", 400, 1, "媒体不存在或不可用"},
		{"transaction failure", "/api/v2/posts", `{"content":"hi"}`, tokens["access-hs256"], errors.New("private SQL failure"), nil, "", 500, 1, "服务器内部错误"},
		{"notification failure after commit", "/api/v2/posts", `{"content":"hi"}`, tokens["access-hs256"], nil, errors.New("private notice failure"), "", 500, 1, "服务器内部错误"},
		{"response media schema failure", "/api/v2/posts", `{"content":"hi"}`, tokens["access-hs256"], nil, nil, "media-ready", 503, 1, "服务暂不可用，请稍后重试。"},
		{"response author missing", "/api/v2/posts", `{"content":"hi"}`, tokens["access-hs256"], nil, nil, "author-missing", 404, 1, "用户不存在"},
		{"normal post", "/api/v2/posts", `{"content":" hi ","author_id":99}`, tokens["access-hs256"], nil, nil, "", 200, 1, "post created"},
		{"empty retweet", "/api/v2/posts/2/retweets", `{}`, tokens["access-hs256"], nil, nil, "", 200, 1, "retweet created"},
		{"invalid retweet path", "/api/v2/posts/01/retweets", `{}`, tokens["access-hs256"], nil, nil, "", 400, 0, "id 参数错误"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newPostCreateFixture()
			s.writeErr = tc.writeErr
			s.noticeErr = tc.noticeErr
			s.fault = tc.fault
			r := httptest.NewRequest("POST", tc.path, strings.NewReader(tc.body))
			r.Header.Set("Content-Type", "application/json")
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
			var out struct {
				Code    int
				Message string
				Data    PostDetail
			}
			if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
			if w.Code != tc.status || out.Message != tc.message || s.created != tc.created || strings.Contains(w.Body.String(), "private SQL") {
				t.Fatalf("status=%d body=%s creates=%d events=%v", w.Code, w.Body.String(), s.created, s.events)
			}
			if w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(w.Header())
			}
			if tc.created > 0 && s.actor != 42 {
				t.Fatal(s.actor)
			}
			if tc.status == 200 {
				if !reflect.DeepEqual(s.events, []string{"create", "notice", "post", "author", "media-ready", "media", "tags", "mentions"}) {
					t.Fatal(s.events)
				}
				if out.Data.PostID != 1 || out.Data.Author.UserID != 7 || out.Code != 200 {
					t.Fatal(out)
				}
			}
			if tc.writeErr != nil && !reflect.DeepEqual(s.events, []string{"create"}) {
				t.Fatal(s.events)
			}
			if tc.noticeErr != nil && !reflect.DeepEqual(s.events, []string{"create", "notice"}) {
				t.Fatal(s.events)
			}
		})
	}
}
