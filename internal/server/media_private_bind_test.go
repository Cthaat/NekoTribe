package server

import (
	"context"
	"database/sql"
	"errors"
	"reflect"
	"testing"
)

func TestPrivateMediaBindPostCreate(t *testing.T) {
	for _, tc := range []struct {
		name, visibility, key string
		denied, checks        bool
		want                  error
	}{
		{"restricted", "private", "private/post/files/42/a.txt", false, true, nil},
		{"followers", "followers", "private/post/files/42/a.txt", false, true, nil},
		{"mentioned", "mentioned", "private/post/files/42/a.txt", false, true, nil},
		{"public", "public", "private/post/files/42/a.txt", false, false, errPostMediaUnavailable},
		{"wrong scope", "private", "private/chat/files/42/a.txt", false, false, errPostMediaUnavailable},
		{"reserved spelling", "private", `PRIVATE\post\files\42\a.txt`, false, false, errPostMediaUnavailable},
		{"unsafe path", "private", "private/post/../a.txt", false, false, errPostMediaUnavailable},
		{"claimed or not ready", "private", "private/post/files/42/a.txt", true, true, errPostMediaUnavailable},
		{"legacy", "public", "posts/files/42/a.txt", false, false, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &createPostState{mediaKeys: map[float64]string{12: tc.key}, privateDenied: tc.denied}
			db := sql.OpenDB(createPostConnector{state})
			defer db.Close()
			_, err := (OracleSessions{db}).CreatePostAtomic(context.Background(), 42, PostCreateInput{
				Content: "hello", Visibility: tc.visibility, MediaIDs: []float64{12, 11},
			})
			if !errors.Is(err, tc.want) || (err == nil && state.commits != 1) || (err != nil && state.rollbacks != 1) {
				t.Fatal(err, state.commits, state.rollbacks)
			}
			var locked, attached []float64
			checked := false
			for _, call := range state.calls {
				switch call.sql {
				case lockPostMediaSQL:
					locked = append(locked, call.args[0].Value.(float64))
				case privateMediaBinding.Post:
					if !reflect.DeepEqual(locked, []float64{11, 12}) || len(call.args) != 2 ||
						call.args[0].Name != "media_id" || call.args[0].Value != float64(12) ||
						call.args[1].Name != "post_id" || call.args[1].Value != int64(100) {
						t.Fatal(locked, call.args)
					}
					checked = true
				case insertPostMediaAtomicSQL:
					attached = append(attached, call.args[1].Value.(float64))
				}
			}
			if checked != tc.checks || !reflect.DeepEqual(locked, []float64{11, 12}) ||
				(err == nil && !reflect.DeepEqual(attached, []float64{12, 11})) || (err != nil && len(attached) != 0) {
				t.Fatal(checked, locked, attached)
			}
		})
	}
}

func TestPrivateMediaBindPostUpdate(t *testing.T) {
	public, followers := "public", "followers"
	replace, clear := []float64{8}, []float64{}
	const key = "private/post/files/42/a.txt"
	for _, tc := range []struct {
		name, current, key string
		visibility         *string
		ids                *[]float64
		retains, denied    bool
		want               error
		query              string
	}{
		{"same restricted target", "private", key, nil, &replace, true, false, nil, privateMediaBinding.Post},
		{"effective patched visibility", "public", key, &followers, &replace, false, false, nil, privateMediaBinding.Post},
		{"other target", "private", key, nil, &replace, false, true, errPostUpdateMedia, privateMediaBinding.Post},
		{"private media on public edit", "private", key, &public, &replace, true, false, errPostUpdateMedia, ""},
		{"public with retained private", "private", key, &public, nil, true, false, errPostUpdateMedia, privateMediaBinding.Retained},
		{"public retaining legacy media", "private", "", &public, nil, false, false, nil, privateMediaBinding.Retained},
		{"clear and publish", "private", key, &public, &clear, true, false, nil, ""},
		{"replace with public and publish", "private", "posts/a.txt", &public, &replace, true, false, nil, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &updatePostState{saved: updatePostInitial(), owner: 42, visibility: tc.current, mediaKey: tc.key,
				retainsPrivate: tc.retains, privateDenied: tc.denied}
			db := sql.OpenDB(updatePostConnector{state})
			defer db.Close()
			err := (OracleSessions{db}).UpdatePostAtomic(context.Background(), 42, 20, PostUpdateInput{
				Visibility: tc.visibility, MediaIDs: tc.ids,
			})
			if !errors.Is(err, tc.want) || (err == nil && state.commits != 1) ||
				(err != nil && (state.rollbacks != 1 || !reflect.DeepEqual(state.saved, updatePostInitial()))) {
				t.Fatal(err, state.commits, state.rollbacks, state.saved)
			}
			var query string
			for _, call := range state.calls {
				if call.sql == privateMediaBinding.Retained || call.sql == privateMediaBinding.Post {
					query = call.sql
					postID := call.args[len(call.args)-1]
					if postID.Name != "post_id" || postID.Value != int64(20) {
						t.Fatal(call.args)
					}
				}
			}
			if query != tc.query {
				t.Fatal(query)
			}
		})
	}
}

func TestPrivateMediaBindChatSend(t *testing.T) {
	for _, tc := range []struct {
		name, key string
		denied    bool
		checks    int
		want      error
	}{
		{"private", "private/chat/files/42/a.png", false, 1, nil},
		{"already bound", "private/chat/files/42/a.png", true, 1, errChatAttachment},
		{"wrong scope", "private/post/files/42/a.png", false, 0, errChatAttachment},
		{"reserved spelling", "Private/chat/files/42/a.png", false, 0, errChatAttachment},
		{"legacy", "posts/files/42/a.png", false, 0, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &chatChannelConnector{historyEnrich: true, sendStatus: "active", sendMediaKey: tc.key, privateDenied: tc.denied}
			db := sql.OpenDB(state)
			defer db.Close()
			message, err := (OracleSessions{DB: db}).SendChatMessage(context.Background(), 42, 7, chatSendInput{
				media: []int64{77},
			}, StorageURLPolicy{PublicBase: "/api/v2/media", CDNBaseURL: "https://example.test"})
			if !errors.Is(err, tc.want) || state.privateChecks != tc.checks ||
				(err == nil && (state.state.commits != 1 || state.writes != 3)) ||
				(err != nil && (state.state.rollbacks != 1 || state.writes != 0)) {
				t.Fatal(err, state.state.commits, state.state.rollbacks, state.writes, state.privateChecks)
			}
			if tc.name == "private" && (len(message.Media) != 1 || message.Media[0].PublicURL != "/api/v2/media/77/content") {
				t.Fatal(message)
			}
		})
	}
}
