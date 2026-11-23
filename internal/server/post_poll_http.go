package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postPollStore interface {
	GetPostPoll(context.Context, *int64, postPollTarget) (*postPoll, error)
	VotePostPoll(context.Context, int64, postPollTarget, []int64) (*postPoll, error)
}

func parsePostPollChoices(raw []byte) ([]int64, error) {
	var body map[string]any
	if json.Unmarshal(raw, &body) != nil || len(body) != 1 {
		return nil, errPostPollInvalid
	}
	options, array := body["option_ids"].([]any)
	if !array || len(options) < 1 || len(options) > postPollsContract.MaxOptions {
		return nil, errPostPollInvalid
	}
	var ids []int64
	for _, rawID := range options {
		id, ok := chatSendID(rawID)
		if !ok || id > int64(postPollsContract.MaxOptions) || slices.Contains(ids, id) {
			return nil, errPostPollInvalid
		}
		ids = append(ids, id)
	}
	return ids, nil
}

const visibleRegularPollPostSQL = `SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0
	AND EXISTS (SELECT 1 FROM v_post_feed_item v WHERE v.post_id=p.post_id)
	AND fn_can_view_post(:viewer_id,p.post_id)=1`

func requireVisiblePollPost(ctx context.Context, db publicProfileQueryer, viewer *int64, target postPollTarget, lock bool) error {
	post := sql.Named("post_id", target.post)
	actor := sql.Named("viewer_id", nullableViewer(viewer))
	if target.group != 0 {
		group := sql.Named("group_id", target.group)
		var row groupPostRow
		var allowed, total int64
		err := row.scan(db.QueryRowContext(ctx, groupContentPostsSQL, actor, group, post,
			sql.Named("start_row", 1), sql.Named("end_row", 1), sql.Named("post_type", "all")), &allowed, &total)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && (allowed != 1 || !row.id.Valid)) {
			return errPostPollMissing
		}
		if err != nil {
			return errSessionStore
		}
		return nil
	}
	query := visibleRegularPollPostSQL
	if lock {
		query += " FOR UPDATE OF p.post_id"
	}
	var found int64
	err := db.QueryRowContext(ctx, query, post, actor).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errPostPollMissing
	}
	if err != nil {
		return errSessionStore
	}
	return nil
}

func (s OracleSessions) GetPostPoll(ctx context.Context, viewer *int64, target postPollTarget) (*postPoll, error) {
	conn, err := s.openPostPollConnection(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err = requireVisiblePollPost(ctx, conn, viewer, target, false); err != nil {
		return nil, err
	}
	poll, err := readPostPoll(ctx, conn, viewer, target, false)
	if err == nil && poll == nil {
		return nil, errPostPollMissing
	}
	return poll, err
}

func (s OracleSessions) VotePostPoll(ctx context.Context, actor int64, target postPollTarget, ids []int64) (*postPoll, error) {
	conn, err := s.openPostPollConnection(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	return votePostPollOn(ctx, conn, actor, target, ids)
}

func votePostPollOn(ctx context.Context, conn *sql.Conn, actor int64, target postPollTarget, ids []int64) (*postPoll, error) {
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return nil, errSessionStore
	}
	defer tx.Rollback()
	user := sql.Named("user_id", actor)
	group := sql.Named("group_id", target.group)
	if target.group != 0 {
		if err := lockGroupContent(ctx, tx, user, group); err != nil {
			if errors.Is(err, errGroupDetailMissing) {
				return nil, errPostPollMissing
			}
			return nil, err
		}
	}
	if err := requireVisiblePollPost(ctx, tx, &actor, target, true); err != nil {
		return nil, err
	}
	if target.group != 0 {
		allowed, err := checkGroupContentPermission(ctx, tx, canPostGroupContentSQL, user, group)
		if err != nil {
			return nil, err
		}
		if !allowed {
			return nil, errPostPollForbidden
		}
	}
	poll, err := readPostPoll(ctx, tx, &actor, target, false)
	if err != nil {
		return nil, err
	}
	if poll == nil {
		return nil, errPostPollMissing
	}
	if poll.Closed {
		return nil, errPostPollClosed
	}
	if len(poll.MyOptionIDs) != 0 {
		return nil, errPostPollVoted
	}
	if !validPostPollChoices(poll, ids) {
		return nil, errPostPollInvalid
	}
	pollID := sql.Named("poll_id", poll.ID)
	ballot, err := tx.ExecContext(ctx, postPollsContract.SQL.InsertBallot, pollID, user)
	if oracleErrorCode(err, "ORA-00001") {
		return nil, errPostPollVoted
	}
	if err != nil {
		return nil, errSessionStore
	}
	affected, err := ballot.RowsAffected()
	if err != nil || affected < 0 || affected > 1 {
		return nil, errSessionStore
	}
	if affected == 0 {
		return nil, errPostPollClosed
	}
	for _, id := range ids {
		if err := writeOneChatRow(ctx, tx, postPollsContract.SQL.InsertVote, pollID, user, sql.Named("option_id", id)); err != nil {
			return nil, err
		}
	}
	receipt, err := readPostPoll(ctx, tx, &actor, target, false)
	if err != nil {
		return nil, err
	}
	if receipt == nil || tx.Commit() != nil {
		return nil, errSessionStore
	}
	return receipt, nil
}

func validPostPollChoices(poll *postPoll, ids []int64) bool {
	if len(ids) == 0 || len(ids) > len(poll.Options) || (!poll.Multiple && len(ids) != 1) {
		return false
	}
	for i, id := range ids {
		if slices.Contains(ids[:i], id) || !slices.ContainsFunc(poll.Options, func(option postPollOption) bool { return option.ID == id }) {
			return false
		}
	}
	return true
}

func postPollFailure(err error) *postFailure {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, errPostPollUnavailable):
		return &postFailure{503, "投票服务暂不可用"}
	case errors.Is(err, errPostPollMissing):
		return &postFailure{404, "帖子或投票不存在"}
	case errors.Is(err, errPostPollForbidden):
		return &postFailure{403, "无权参与群组投票"}
	case errors.Is(err, errPostPollInvalid):
		return &postFailure{400, "投票选项参数错误"}
	case errors.Is(err, errPostPollCutoff):
		return &postFailure{400, "投票截止时间必须晚于当前时间"}
	case errors.Is(err, errPostPollClosed):
		return &postFailure{409, "投票已截止"}
	case errors.Is(err, errPostPollVoted):
		return &postFailure{409, "已提交选票"}
	default:
		return &postFailure{500, "服务器内部错误"}
	}
}

func postPollRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) bool {
	path := r.URL.EscapedPath()
	var rawGroup string
	var group bool
	if relative, ok := strings.CutPrefix(path, "/api/v2/groups/"); ok {
		parts := strings.SplitN(relative, "/", 3)
		if len(parts) != 3 || parts[1] != "posts" {
			return false
		}
		rawGroup, path, group = parts[0], parts[2], true
	} else if relative, ok := strings.CutPrefix(path, "/api/v2/posts/"); ok {
		path = relative
	} else {
		return false
	}
	rawPost, suffix, _ := strings.Cut(path, "/")
	vote := suffix == "poll/vote" && r.Method == http.MethodPost
	if !vote && (suffix != "poll" || r.Method != http.MethodGet) {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	var viewer *int64
	if group || vote || accessToken(r) != "" {
		actor, ok := interactionActor(w, r, codec, repository)
		if !ok {
			return true
		}
		viewer = &actor
	}
	var target postPollTarget
	if group {
		var ok bool
		target.group, ok = groupContentPostID(rawGroup)
		if !ok {
			respond(w, 400, 40001, "id 参数错误", nil)
			return true
		}
	}
	var ok bool
	target.post, ok = groupContentPostID(rawPost)
	if !ok {
		message := "id 参数错误"
		if group {
			message = "post_id 参数错误"
		}
		respond(w, 400, 40001, message, nil)
		return true
	}
	var choices []int64
	if vote {
		const limit = 4096
		raw, readErr := io.ReadAll(io.LimitReader(r.Body, limit+1))
		var err error
		choices, err = parsePostPollChoices(raw)
		if readErr != nil || len(raw) > limit || err != nil {
			respond(w, 400, 40001, "option_ids 参数错误", nil)
			return true
		}
	}
	store, ok := repository.(postPollStore)
	if !ok {
		respond(w, 503, 50301, "投票服务暂不可用", nil)
		return true
	}
	message := "success"
	var poll *postPoll
	var err error
	if vote {
		message = "vote recorded"
		poll, err = store.VotePostPoll(r.Context(), *viewer, target, choices)
	} else {
		poll, err = store.GetPostPoll(r.Context(), viewer, target)
	}
	if failure := postPollFailure(err); failure != nil {
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
		return true
	}
	respond(w, 200, 200, message, poll)
	return true
}
