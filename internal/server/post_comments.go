package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type CommentListQuery struct {
	Page      SessionPage
	Sort      string
	CommentID int64
}
type commentStats struct {
	Likes   float64 `json:"likes_count"`
	Replies float64 `json:"replies_count"`
}
type commentViewer struct {
	Liked     bool `json:"is_liked"`
	CanDelete bool `json:"can_delete"`
}
type PostComment struct {
	ID           int64         `json:"comment_id"`
	PostID       int64         `json:"post_id"`
	AuthorID     int64         `json:"-"`
	Author       PublicUser    `json:"author"`
	ParentID     *int64        `json:"parent_comment_id"`
	RootID       *int64        `json:"root_comment_id"`
	Content      string        `json:"content"`
	LikesCount   float64       `json:"-"`
	RepliesCount float64       `json:"-"`
	Liked        bool          `json:"-"`
	Stats        commentStats  `json:"stats"`
	Viewer       commentViewer `json:"viewer_state"`
	CreatedAt    string        `json:"created_at"`
	UpdatedAt    string        `json:"updated_at"`
}
type postCommentsStore interface {
	ListPostComments(context.Context, int64, int64, CommentListQuery) ([]PostComment, int64, bool, error)
}

type commentScanner interface{ Scan(...any) error }

func scanPostComment(row commentScanner) (PostComment, error) {
	var item PostComment
	var parent, root, liked sql.NullInt64
	var content sql.NullString
	var created, updated sql.NullTime
	var likes, replies sql.NullFloat64
	if err := row.Scan(&item.ID, &item.PostID, &item.AuthorID, &parent, &root, &content, &created, &updated, &likes, &replies, &liked); err != nil {
		return PostComment{}, err
	}
	item.ParentID = nullableInt(parent)
	item.RootID = nullableInt(root)
	item.Content = content.String
	item.LikesCount = likes.Float64
	item.RepliesCount = replies.Float64
	item.Liked = liked.Int64 == 1
	if value := profileDate(created); value != nil {
		item.CreatedAt = *value
	}
	if value := profileDate(updated); value != nil {
		item.UpdatedAt = *value
	}
	return item, nil
}

func listPostComments(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	user, id, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	store, ok := repository.(postCommentsStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	values := parseSessionQuery(r.URL.RawQuery)
	query := CommentListQuery{Page: sessionPagination(values), Sort: listQueryString(values, "sort", "newest")}
	if candidates, exists := values["comment_id"]; exists {
		if len(candidates) != 1 || !publicID.MatchString(candidates[0]) {
			respond(w, 400, 40001, "comment_id 参数错误", nil)
			return
		}
		commentID, err := strconv.ParseInt(candidates[0], 10, 64)
		if err != nil || commentID > 9007199254740991 {
			respond(w, 400, 40001, "comment_id 参数错误", nil)
			return
		}
		query.CommentID = commentID
		query.Page = SessionPage{Page: 1, PageSize: 1, Start: 1, End: 1}
	}
	items, total, visible, err := store.ListPostComments(r.Context(), user, id, query)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !visible {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	profiles, ok := repository.(publicProfileStore)
	if !ok && len(items) > 0 {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	for i := range items {
		author, found, e := profiles.PublicProfile(r.Context(), user, items[i].AuthorID)
		if e != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		if !found {
			respond(w, 404, 40401, "用户不存在", nil)
			return
		}
		author.AvatarURL, e = normalizeAvatarURL(config.Storage, author.AvatarURL)
		if e != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		items[i].Author = author
		items[i].Stats = commentStats{items[i].LikesCount, items[i].RepliesCount}
		items[i].Viewer = commentViewer{items[i].Liked, items[i].AuthorID == user}
	}
	if items == nil {
		items = []PostComment{}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(struct {
		Code    int           `json:"code"`
		Message string        `json:"message"`
		Data    []PostComment `json:"data"`
		Meta    any           `json:"meta"`
	}{200, "success", items, map[string]any{"page": query.Page.Page, "page_size": query.Page.PageSize, "total": total, "has_next": query.Page.End < float64(total)}})
}

func commentListSQL(sort string, targeted bool) (string, string) {
	order := "c.created_at DESC"
	if sort == "oldest" {
		order = "c.created_at ASC"
	} else if sort == "popular" {
		order = "c.likes_count DESC, c.created_at DESC"
	}
	where := ` FROM v_post_comment_list_item c
		JOIN n_posts p ON p.post_id=c.post_id
		JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
		JOIN n_users comment_author ON comment_author.user_id=c.user_id AND comment_author.is_active=1
		WHERE c.post_id=:post_id AND fn_can_view_post(:viewer_id,c.post_id)=1
		AND NOT EXISTS (
			SELECT 1 FROM n_user_blocks b
			WHERE (b.user_id=:viewer_id AND b.target_user_id=c.user_id)
			   OR (b.target_user_id=:viewer_id AND b.user_id=c.user_id)
		)`
	count := `SELECT COUNT(*)` + where
	if targeted {
		where += ` AND c.comment_id=:comment_id`
	}
	list := `SELECT comment_id,post_id,user_id,parent_comment_id,root_comment_id,content,created_at,updated_at,likes_count,replies_count,is_liked FROM (SELECT c.comment_id,c.post_id,c.user_id,c.parent_comment_id,c.root_comment_id,DBMS_LOB.SUBSTR(c.content,4000,1) AS content,c.created_at,c.updated_at,c.likes_count,c.replies_count,CASE WHEN EXISTS (SELECT 1 FROM n_comment_likes cl WHERE cl.comment_id=c.comment_id AND cl.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked,ROW_NUMBER() OVER (ORDER BY ` + order + `) AS rn` + where + `) WHERE rn BETWEEN :start_row AND :end_row`
	return count, list
}

func (s OracleSessions) ListPostComments(ctx context.Context, user, id int64, query CommentListQuery) ([]PostComment, int64, bool, error) {
	const visibleSQL = `SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1`
	var visibleID int64
	err := s.DB.QueryRowContext(ctx, visibleSQL, sql.Named("post_id", id), sql.Named("viewer_id", user)).Scan(&visibleID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, 0, false, nil
	}
	if err != nil {
		return nil, 0, false, errSessionStore
	}
	targeted := query.CommentID != 0
	countSQL, listSQL := commentListSQL(query.Sort, targeted)
	var total int64
	args := []any{sql.Named("post_id", id), sql.Named("viewer_id", user)}
	if targeted {
		args = append(args, sql.Named("comment_id", query.CommentID))
	} else {
		if err = s.DB.QueryRowContext(ctx, countSQL, args...).Scan(&total); err != nil {
			return nil, 0, false, errSessionStore
		}
	}
	rows, err := s.DB.QueryContext(ctx, listSQL, append(args, sql.Named("start_row", query.Page.Start), sql.Named("end_row", query.Page.End))...)
	if err != nil {
		return nil, 0, false, errSessionStore
	}
	items := []PostComment{}
	for rows.Next() {
		item, scanErr := scanPostComment(rows)
		if scanErr != nil {
			rows.Close()
			return nil, 0, false, errSessionStore
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		rows.Close()
		return nil, 0, false, errSessionStore
	}
	if rows.Close() != nil {
		return nil, 0, false, errSessionStore
	}
	if targeted {
		total = int64(len(items))
	}
	return items, total, true, nil
}
