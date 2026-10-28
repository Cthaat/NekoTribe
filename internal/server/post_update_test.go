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

type postUpdateFixture struct {
	*postCreateFixture
	updated int
	edit    PostUpdateInput
	err     error
}

func (s *postUpdateFixture) ReadVisiblePost(_ context.Context, viewer *int64, id int64) (PostDetail, bool, error) {
	if viewer == nil || *viewer != 42 || id != 20 {
		return PostDetail{}, false, errors.New("wrong update read identity")
	}
	return s.post, !s.missing, s.mark("post")
}

func (s *postUpdateFixture) UpdatePostAtomic(_ context.Context, user, id int64, input PostUpdateInput) error {
	if user != 42 || id != 20 {
		panic("wrong update identity")
	}
	s.updated++
	s.edit = input
	s.events = append(s.events, "update")
	return s.err
}
func TestPostUpdateHTTP(t *testing.T) {
	codec, tokens := fixture(t)
	for _, method := range []string{"PATCH", "PUT"} {
		for _, tc := range []struct {
			body    string
			err     error
			status  int
			message string
		}{{`{"content":"new"}`, nil, 200, "post updated"}, {`[]`, nil, 400, "请求体必须是 JSON 对象"}, {`{"visibility":null}`, nil, 400, "visibility 参数错误"}, {`{}`, errPostUpdateNotOwner, 422, "只能修改自己的帖子"}, {`{}`, errPostReferenceUnavailable, 404, "帖子不存在"}, {`{}`, errPostUpdateMedia, 400, "附件不存在或无权使用"}, {`{}`, errPostContentEmpty, 400, "content 不能为空"}, {`{}`, errors.New("private failure"), 500, "服务器内部错误"}} {
			s := &postUpdateFixture{postCreateFixture: newPostCreateFixture(), err: tc.err}
			s.post.PostID = 20
			r := httptest.NewRequest(method, "/api/v2/posts/20", strings.NewReader(tc.body))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
			var out struct{ Message string }
			if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
			if w.Code != tc.status || out.Message != tc.message || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("%s %d %s", method, w.Code, w.Body.String())
			}
			if s.created != 0 {
				t.Fatal("created a post during update")
			}
			for _, event := range s.events {
				if event == "notice" || event == "views" {
					t.Fatal(s.events)
				}
			}
		}
	}
}
func TestSharedPostUpdateRequests(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/post-update-request.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID       string
			Body     json.RawMessage
			Expected struct {
				Status  int
				Message string
				Input   map[string]interface{}
			}
		}
	}
	if err = json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, tc := range fixture.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			request := httptest.NewRequest("PATCH", "/api/v2/posts/20", strings.NewReader(string(tc.Body)))
			request.Header.Set("Content-Type", "application/json")
			body, ok := readPostCreateBody(request)
			if !ok {
				t.Fatal("valid vector was not an object")
			}
			input, message := readPostUpdateInput(body)
			if tc.Expected.Status == 400 {
				if message != tc.Expected.Message {
					t.Fatal(message, tc.Expected.Message)
				}
				return
			}
			if message != "" {
				t.Fatal(message)
			}
			data, err := json.Marshal(input)
			if err != nil {
				t.Fatal(err)
			}
			var actual map[string]interface{}
			if err = json.Unmarshal(data, &actual); err != nil {
				t.Fatal(err)
			}
			if input.Location != nil && *input.Location == "" {
				actual["location"] = nil
			}
			if !reflect.DeepEqual(actual, tc.Expected.Input) {
				t.Fatalf("actual=%#v expected=%#v", actual, tc.Expected.Input)
			}
		})
	}
}
