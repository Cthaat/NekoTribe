package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var profilePinnedPostSQL = func() map[string]string {
	var definition struct {
		SQL map[string]string `json:"sql"`
	}
	if json.Unmarshal(contracts.ProfilePinnedPost, &definition) != nil {
		panic("invalid profile pinned post contract")
	}
	return definition.SQL
}()

var (
	errProfilePinUnavailable  = errors.New("profile pin schema unavailable")
	errProfilePinPostMissing  = errors.New("eligible post not found")
	errProfilePinOwnerMissing = errors.New("pin owner not found")
)

type profilePinnedPostStore interface {
	ProfilePinnedPostID(context.Context, int64, int64) (int64, error)
	SetProfilePinnedPost(context.Context, int64, *int64) error
}

func (s OracleSessions) profilePinConnection(ctx context.Context) (*sql.Conn, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errSessionStore
	}
	var catalog schemaCatalog
	if json.Unmarshal(contracts.ProfilePinnedPostSchemaCatalog, &catalog) != nil ||
		validateFeatureSchema(ctx, conn, catalog, "profile-pinned-post") != nil {
		_ = conn.Close()
		return nil, errProfilePinUnavailable
	}
	return conn, nil
}

func (s OracleSessions) ProfilePinnedPostID(ctx context.Context, viewer, profile int64) (int64, error) {
	conn, err := s.profilePinConnection(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	var id int64
	err = conn.QueryRowContext(ctx, profilePinnedPostSQL["read"], sql.Named("profile_id", profile), sql.Named("viewer_id", viewer)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, errSessionStore
	}
	return id, nil
}

func (s OracleSessions) SetProfilePinnedPost(ctx context.Context, owner int64, post *int64) error {
	conn, err := s.profilePinConnection(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return errSessionStore
	}
	defer tx.Rollback()
	if err := writeProfilePinnedPost(ctx, tx, owner, post); err != nil {
		return err
	}
	if tx.Commit() != nil {
		return errSessionStore
	}
	return nil
}

func writeProfilePinnedPost(ctx context.Context, tx *sql.Tx, owner int64, post *int64) error {
	userID := sql.Named("user_id", owner)
	var found int64
	err := tx.QueryRowContext(ctx, profilePinnedPostSQL["owner"], userID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errProfilePinOwnerMissing
	}
	if err != nil {
		return errSessionStore
	}
	if post == nil {
		removed, err := postTxExecute(ctx, tx, profilePinnedPostSQL["remove"], userID)
		if err != nil || removed < 0 || removed > 1 {
			return errSessionStore
		}
		return nil
	}
	postID := sql.Named("post_id", *post)
	err = tx.QueryRowContext(ctx, profilePinnedPostSQL["eligible"], postID, userID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errProfilePinPostMissing
	}
	if err != nil {
		return errSessionStore
	}
	return writeOneChatRow(ctx, tx, profilePinnedPostSQL["write"], userID, postID)
}

func writeProfilePinnedPostError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errProfilePinUnavailable):
		respond(w, 503, 50301, "置顶服务暂不可用", nil)
	case errors.Is(err, errProfilePinPostMissing):
		respond(w, 404, 40401, "帖子不存在", nil)
	case errors.Is(err, errProfilePinOwnerMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
}

func profilePinnedPostRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	base, match := strings.CutSuffix(r.URL.EscapedPath(), "/pinned-post")
	raw, valid := publicProfileSegment(base)
	get := r.Method == http.MethodGet
	put := r.Method == http.MethodPut
	if !match || !valid || !get && (raw != "me" || !put && r.Method != http.MethodDelete) {
		return false
	}
	store, _ := repo.(profilePinnedPostStore)
	if get {
		viewer, profile, ok := interactionIdentity(w, r, codec, repo, raw)
		if ok {
			getProfilePinnedPost(w, r.Context(), repo, store, storage, viewer, profile)
		}
		return true
	}
	owner, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	var post *int64
	if put {
		const limit = 4096
		raw, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
		var body map[string]any
		if err != nil || len(raw) > limit || json.Unmarshal(raw, &body) != nil || len(body) != 1 {
			respond(w, 400, 40001, "post_id 参数错误", nil)
			return true
		}
		id, valid := chatSendID(body["post_id"])
		if !valid {
			respond(w, 400, 40001, "post_id 参数错误", nil)
			return true
		}
		post = &id
	}
	if store == nil {
		writeProfilePinnedPostError(w, errProfilePinUnavailable)
		return true
	}
	if err := store.SetProfilePinnedPost(r.Context(), owner, post); err != nil {
		writeProfilePinnedPostError(w, err)
		return true
	}
	if put {
		respond(w, 200, 200, "success", struct {
			PostID int64 `json:"post_id"`
		}{*post})
	} else {
		respond(w, 200, 200, "success", nil)
	}
	return true
}

func getProfilePinnedPost(w http.ResponseWriter, ctx context.Context, repo SessionRepository, store profilePinnedPostStore,
	storage StorageURLPolicy, viewer, profile int64) {
	if store == nil {
		writeProfilePinnedPostError(w, errProfilePinUnavailable)
		return
	}
	id, err := store.ProfilePinnedPostID(ctx, viewer, profile)
	if err != nil {
		writeProfilePinnedPostError(w, err)
		return
	}
	var pinned *PostDetail
	if id != 0 {
		detail, ok := repo.(postDetailStore)
		if !ok {
			writeProfilePinnedPostError(w, errSessionStore)
			return
		}
		post, found, err := detail.ReadVisiblePost(ctx, &viewer, id)
		if err != nil {
			writeProfilePinnedPostError(w, err)
			return
		}
		if found && post.Author.UserID == profile {
			post, failure := hydratePost(ctx, detail, &viewer, post, storage)
			if failure == nil {
				pinned = &post
			} else if failure.status != http.StatusNotFound {
				respond(w, failure.status, failure.status*100+1, failure.message, nil)
				return
			}
		}
	}
	respond(w, 200, 200, "success", struct {
		Post *PostDetail `json:"post"`
	}{pinned})
}
