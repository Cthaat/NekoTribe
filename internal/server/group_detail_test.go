package server

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
)

type groupDetailFixture struct{ SessionRepository }

func (groupDetailFixture) ReadGroupContent(_ context.Context, viewer int64, req groupContentRequest, _ StorageURLPolicy) (any, int64, error) {
	if viewer != 42 || req.group != 7 {
		return nil, 0, errGroupDetailMissing
	}
	if req.comments && req.post == 5 {
		if req.commentID == 31 && req.page.Start == 1 && req.page.End == 1 {
			return []groupComment{{ID: 31, Post: 5}}, 1, nil
		}
		return []groupComment{}, 12, nil
	}
	if req.post == 5 && req.page.Start == 1 && req.page.End == 1 {
		return groupPost{ID: 5, Group: 7}, 1, nil
	}
	if req.post == 0 {
		return []groupPost{}, 12, nil
	}
	return nil, 0, &groupMembershipFailure{404, "群组帖子不存在"}
}

func TestGroupContentReadRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, groupDetailFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		path, want string
		status     int
	}{
		{"/7/posts?page=3&page_size=5", `"total":12`, 200},
		{"/7/posts/5", `"meta":null`, 200},
		{"/7/posts/5/comments?page=2", `"data":[]`, 200},
		{"/7/posts/5/comments?comment_id=31&page=9", `"comment_id":31`, 200},
		{"/7/posts/5/comments?comment_id=31&comment_id=31", "comment_id 参数错误", 400},
		{"/7/posts/5/comments?comment_id=031", "comment_id 参数错误", 400},
		{"/8/posts", "群组不存在", 404},
		{"/7/posts/6/comments", "群组帖子不存在", 404},
		{"/7/posts/9007199254740992", "post_id 参数错误", 400},
		{"/7/posts?type=unknown", "type 参数错误", 400},
		{"/7/posts/5/comments?sort=unknown", "sort 参数错误", 400},
	} {
		req := httptest.NewRequest("GET", "/api/v2/groups"+tc.path, nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" || !strings.Contains(w.Body.String(), tc.want) {
			t.Errorf("%s: %d %s", tc.path, w.Code, w.Body)
		}
	}
}

func (groupDetailFixture) GroupDetail(_ context.Context, viewer int64, key groupLookup, _ StorageURLPolicy) (groupDetail, error) {
	if viewer != 42 || (key.id != 7 && key.slug != "neko") {
		return groupDetail{}, errGroupDetailMissing
	}
	return groupDetail{ID: 7, Slug: "neko", Tags: []string{"chat"}}, nil
}

func TestGroupDetailLookups(t *testing.T) {
	codec, tokens := fixture(t)
	handler := NewHandler(codec, groupDetailFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		path   string
		status int
	}{
		{"/api/v2/groups/7", 200},
		{"/api/v2/groups/by-slug/neko", 200},
		{"/api/v2/groups/by-slug/missing", 404},
		{"/api/v2/groups/9007199254740992", 400},
	} {
		req := httptest.NewRequest("GET", tc.path, nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		if recorder.Code != tc.status || recorder.Header().Get("Cache-Control") != "private, no-store" ||
			tc.status == 200 && !strings.Contains(recorder.Body.String(), `"tags":["chat"]`) {
			t.Errorf("%s: %d %s", tc.path, recorder.Code, recorder.Body)
		}
	}
}

func TestGroupDetailRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	handler := NewHandler(codec, store(), CorsPolicy{})
	for _, path := range []string{"/api/v2/groups/42", "/api/v2/groups/by-slug/neko"} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest("GET", path, nil))
		if recorder.Code != 401 || recorder.Header().Get("Cache-Control") != "private, no-store" ||
			!strings.Contains(recorder.Body.String(), "40101") {
			t.Errorf("%s: %d %s", path, recorder.Code, recorder.Body)
		}
	}
}

func (groupDetailFixture) ChangeGroupMembership(_ context.Context, user, group int64, join bool, invite string) (*groupMembershipResult, error) {
	if user != 42 || group != 7 {
		return nil, &groupMembershipFailure{404, "群组不存在"}
	}
	if !join {
		return nil, nil
	}
	status := "pending"
	if invite == "AB12" {
		status = "active"
	}
	return &groupMembershipResult{8, group, user, "member", status}, nil
}

func TestGroupMembershipRoute(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, groupDetailFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		method, group, body, want string
		status                    int
	}{
		{"POST", "7", "{}", `"status":"pending"`, 200},
		{"POST", "7", `{"invite_code":" ab12 "}`, `"status":"active"`, 200},
		{"POST", "7", `{"invite_code":3}`, "40001", 400},
		{"DELETE", "7", "", `"data":null`, 200},
		{"POST", "9", "", "40401", 404},
	} {
		req := httptest.NewRequest(tc.method, "/api/v2/groups/"+tc.group+"/members/current", strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.want) || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s: %d %s", tc.method, tc.group, w.Code, w.Body)
		}
	}
}

func TestGroupListsRequireSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	for _, path := range []string{"/api/v2/groups", "/api/v2/groups/popular", "/api/v2/users/me/groups", "/api/v2/groups/7/members"} {
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s: %d %s", path, w.Code, w.Body)
		}
	}
}

func TestGroupAdmissionRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	for method, path := range map[string]string{
		"PUT":    "/api/v2/groups/7/members/12/approval-status",
		"DELETE": "/api/v2/groups/7/members/9",
	} {
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest(method, path, nil))
		if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s: %d %s", method, path, w.Code, w.Body)
		}
	}
}

func TestGroupModerationRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	for _, tc := range []struct{ method, resource string }{
		{"PATCH", "role"}, {"PATCH", "roles"}, {"PUT", "mute-status"}, {"DELETE", "mute-status"},
	} {
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest(tc.method, "/api/v2/groups/7/members/9/"+tc.resource, nil))
		if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s: %d %s", tc.method, tc.resource, w.Code, w.Body)
		}
	}
}

func TestGroupOwnershipRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	w := httptest.NewRecorder()
	app.ServeHTTP(w, httptest.NewRequest("PUT", "/api/v2/groups/7/ownership", nil))
	if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

func TestGroupDissolutionRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	w := httptest.NewRecorder()
	app.ServeHTTP(w, httptest.NewRequest("DELETE", "/api/v2/groups/7", nil))
	if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

func TestGroupSettingsRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	w := httptest.NewRecorder()
	app.ServeHTTP(w, httptest.NewRequest("PATCH", "/api/v2/groups/7", nil))
	if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

func TestGroupInviteReadsRequireSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	for _, path := range []string{"/api/v2/groups/7/invites", "/api/v2/groups/invite-codes/ABC"} {
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body)
		}
	}
}

func TestGroupInviteCreateRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	w := httptest.NewRecorder()
	app.ServeHTTP(w, httptest.NewRequest("POST", "/api/v2/groups/7/invites", nil))
	if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

func TestDirectedGroupInvitationRequiresSession(t *testing.T) {
	codec, _ := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	for method, path := range map[string]string{
		"GET":  "/api/v2/users/me/group-invites",
		"POST": "/api/v2/groups/invites/7/responses",
	} {
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest(method, path, nil))
		if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s: %d %s", method, path, w.Code, w.Body)
		}
	}
}

func (groupDetailFixture) GroupInvites(_ context.Context, viewer, group int64, page SessionPage, status string, _ StorageURLPolicy) ([]groupInviteItem, int64, error) {
	if viewer != 42 || group != 7 || page.Page != 2 || status != "pending" {
		return nil, 0, errSessionStore
	}
	return []groupInviteItem{}, 1, nil
}

func (groupDetailFixture) GroupInvitePreview(_ context.Context, viewer int64, code string, _ StorageURLPolicy) (groupInvitePreview, error) {
	if viewer != 42 {
		return groupInvitePreview{}, errSessionStore
	}
	if code != "ABC" {
		return groupInvitePreview{}, &groupMembershipFailure{422, "邀请码无效或已过期"}
	}
	return groupInvitePreview{Valid: true, Group: groupDetail{ID: 7}}, nil
}

func TestGroupInviteReadsRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, groupDetailFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		path, fragment string
		status         int
	}{
		{"7/invites?page=2&status=pending", `"total":1`, 200},
		{"7/invites?status=active", "40001", 400},
		{"invite-codes/%20aBc%20", `"is_valid":true`, 200},
		{"invite-codes/bad-code", "40001", 400},
		{"invite-codes/EXPIRED", "42201", 422},
	} {
		r := httptest.NewRequest("GET", "/api/v2/groups/"+tc.path, nil)
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, r)
		if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.fragment) || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s: %d %s", tc.path, w.Code, w.Body)
		}
	}
}

func (groupDetailFixture) ListGroupMembers(_ context.Context, viewer, group int64, request groupMemberRequest, _ StorageURLPolicy) ([]groupMember, int64, error) {
	if viewer != 42 {
		return nil, 0, errSessionStore
	}
	switch group {
	case 7:
		if request.role != "member" || request.status != "pending" || request.page.Start != 3 {
			return nil, 0, errSessionStore
		}
		return []groupMember{{MemberID: 12, User: PublicUser{UserID: 9}, Role: "member", Status: "pending"}}, 6, nil
	case 8:
		return nil, 3, nil
	case 9:
		return nil, 0, errGroupMemberListForbidden
	default:
		return nil, 0, errGroupDetailMissing
	}
}

func TestGroupMemberListFiltersAndEnvelope(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, groupDetailFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		path, field string
		status      int
	}{
		{"7/members?role=member&status=pending&page=2&page_size=2", `"has_next":true`, 200},
		{"8/members?page=4", `"data":[]`, 200},
		{"9/members", "40301", 403},
		{"10/members", "40401", 404},
		{"7/members?status=pending&status=active", "40001", 400},
		{"7/members?role=invalid", "40001", 400},
		{"9007199254740992/members", "40001", 400},
	} {
		req := httptest.NewRequest("GET", "/api/v2/groups/"+tc.path, nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.field) || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s: %d %s", tc.path, w.Code, w.Body)
		}
	}
}

func (groupDetailFixture) ListGroups(_ context.Context, viewer int64, req groupListRequest, _ StorageURLPolicy) ([]groupListItem, int64, error) {
	if viewer != 42 {
		return nil, 0, errSessionStore
	}
	switch req.mode {
	case "popular":
		if req.limit != 50 {
			return nil, 0, errSessionStore
		}
		score := 4.2
		return []groupListItem{{groupDetail: groupDetail{ID: 7}, ActivityScore: &score}}, 0, nil
	case "discover":
		if req.search != "neko" || req.privacy != "public" || req.category != "tech" || req.page.Start != 3 {
			return nil, 0, errSessionStore
		}
		return []groupListItem{{groupDetail: groupDetail{ID: 7}}}, 9, nil
	case "mine":
		return nil, 0, nil
	default:
		return nil, 0, errSessionStore
	}
}

func TestGroupListFiltersAndEnvelope(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, groupDetailFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		path, want string
		status     int
	}{
		{"/api/v2/groups?q=+NEKO+&privacy=public&category=tech&page=2&page_size=2", `"has_next":true`, 200},
		{"/api/v2/groups/popular?limit=80", `"activity_score":4.2`, 200},
		{"/api/v2/users/me/groups", `"data":[]`, 200},
		{"/api/v2/users/me/groups?category=invalid", "40001", 400},
	} {
		req := httptest.NewRequest("GET", tc.path, nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.want) || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s: %d %s", tc.path, w.Code, w.Body)
		}
	}
}
