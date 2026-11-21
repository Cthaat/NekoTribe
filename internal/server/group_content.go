package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupContentRequest struct {
	group, post int64
	commentID   int64
	comments    bool
	page        SessionPage
	order       string
}

type groupContentStore interface {
	ReadGroupContent(context.Context, int64, groupContentRequest, StorageURLPolicy) (any, int64, error)
}

type groupPost struct {
	ID           int64      `json:"post_id"`
	Group        int64      `json:"group_id"`
	Author       PublicUser `json:"author"`
	Content      string     `json:"content"`
	Media        []string   `json:"media_urls"`
	Pinned       bool       `json:"is_pinned"`
	Announcement bool       `json:"is_announcement"`
	Likes        int64      `json:"likes_count"`
	Comments     int64      `json:"comments_count"`
	Views        int64      `json:"views_count"`
	Liked        bool       `json:"is_liked_by_me"`
	Created      string     `json:"created_at"`
	Updated      string     `json:"updated_at"`
}

type groupComment struct {
	ID        int64       `json:"comment_id"`
	Post      int64       `json:"post_id"`
	Author    PublicUser  `json:"author"`
	Parent    *int64      `json:"parent_comment_id"`
	ReplyTo   *PublicUser `json:"reply_to_user"`
	Content   string      `json:"content"`
	Likes     int64       `json:"likes_count"`
	Liked     bool        `json:"is_liked_by_me"`
	CanDelete bool        `json:"can_delete_by_me"`
	Created   string      `json:"created_at"`
	Updated   string      `json:"updated_at"`
}

// go-oracledb requires SELECT as the first keyword for a read.
const groupContentPostsSQL = `SELECT group_allowed,total,post_id,group_id,author_id,content,media_urls,
  is_pinned,is_announcement,likes_count,comments_count,views_count,created_at,updated_at,is_liked_by_me
FROM (
WITH allowed_group AS (
  SELECT g.group_id
  FROM n_groups g
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
    AND (g.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=g.group_id AND m.user_id=:viewer_id AND m.status='active'))
), ranked AS (
  SELECT p.post_id,p.group_id,p.author_id,p.content,p.media_urls,p.is_pinned,p.is_announcement,p.likes_count,p.comments_count,p.views_count,p.created_at,p.updated_at,
    CASE WHEN EXISTS (SELECT 1 FROM n_group_post_likes l
      WHERE l.post_id=p.post_id AND l.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked_by_me,
    ROW_NUMBER() OVER (ORDER BY CASE WHEN p.is_pinned=1 THEN 2 WHEN p.is_announcement=1 THEN 1 ELSE 0 END DESC,
      p.created_at DESC,p.post_id DESC) AS rn
  FROM allowed_group g
  JOIN n_group_posts p ON p.group_id=g.group_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  WHERE (:post_id=0 OR p.post_id=:post_id)
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=p.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=p.author_id))
    AND (:post_type='all' OR :post_type='pinned' AND p.is_pinned=1
      OR :post_type='announcement' AND p.is_announcement=1)
)
SELECT (SELECT COUNT(*) FROM allowed_group) AS group_allowed,t.total,
  r.post_id,r.group_id,r.author_id,r.content,r.media_urls,r.is_pinned,r.is_announcement,r.likes_count,r.comments_count,r.views_count,r.created_at,r.updated_at,r.is_liked_by_me,r.rn
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
) ORDER BY rn`

const groupContentCommentsSQL = `WITH allowed_group AS (
  SELECT g.group_id
  FROM n_groups g
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
    AND (g.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=g.group_id AND m.user_id=:viewer_id AND m.status='active'))
), allowed_post AS (
  SELECT p.post_id,p.group_id
  FROM allowed_group g
  JOIN n_group_posts p ON p.group_id=g.group_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  WHERE p.post_id=:post_id
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=p.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=p.author_id))
), ranked AS (
  SELECT c.comment_id,c.post_id,c.author_id,c.parent_comment_id,
    CASE WHEN EXISTS (SELECT 1 FROM n_users reply_author
      WHERE reply_author.user_id=c.reply_to_user_id AND reply_author.is_active=1
        AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
          WHERE (b.user_id=:viewer_id AND b.target_user_id=reply_author.user_id)
             OR (b.target_user_id=:viewer_id AND b.user_id=reply_author.user_id)))
      THEN c.reply_to_user_id END AS reply_to_user_id,
    c.content,c.likes_count,c.created_at,c.updated_at,
    CASE WHEN EXISTS (SELECT 1 FROM n_group_comment_likes l
      WHERE l.comment_id=c.comment_id AND l.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked_by_me,
    CASE WHEN c.author_id=:viewer_id OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=p.group_id AND m.user_id=:viewer_id AND m.status='active'
        AND m.role IN ('owner','admin','moderator')) THEN 1 ELSE 0 END AS can_delete_by_me,
    ROW_NUMBER() OVER (ORDER BY
      CASE WHEN :comment_sort='popular' THEN c.likes_count END DESC,
      CASE WHEN :comment_sort='oldest' THEN c.created_at END ASC,
      CASE WHEN :comment_sort='oldest' THEN c.comment_id END ASC,
      c.created_at DESC,c.comment_id DESC) AS rn
  FROM allowed_post p
  JOIN n_group_comments c ON c.post_id=p.post_id AND c.is_deleted=0
  JOIN n_users comment_author ON comment_author.user_id=c.author_id AND comment_author.is_active=1
  WHERE (:target_comment_id=0 OR c.comment_id=:target_comment_id)
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=c.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=c.author_id))
)
SELECT (SELECT COUNT(*) FROM allowed_group) AS group_allowed,
  (SELECT COUNT(*) FROM allowed_post) AS post_allowed,t.total,
  r.comment_id,r.post_id,r.author_id,r.parent_comment_id,r.reply_to_user_id,r.content,r.likes_count,r.created_at,r.updated_at,r.is_liked_by_me,r.can_delete_by_me
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn`

type groupPostRow struct {
	id, group, author, pinned, announcement, likes, comments, views, liked sql.NullInt64
	content, media                                                         sql.NullString
	created, updated                                                       sql.NullTime
}

type groupCommentRow struct {
	id, post, author, parent, reply, likes, liked, canDelete sql.NullInt64
	content                                                  sql.NullString
	created, updated                                         sql.NullTime
}

func (r *groupCommentRow) destinations() []any {
	return []any{&r.id, &r.post, &r.author, &r.parent, &r.reply, &r.content, &r.likes,
		&r.created, &r.updated, &r.liked, &r.canDelete}
}

func hydrateGroupComment(ctx context.Context, db publicProfileQueryer, viewer int64, r groupCommentRow, storage StorageURLPolicy) (groupComment, error) {
	author, err := readGroupPublicUser(ctx, db, viewer, r.author.Int64, storage)
	if err != nil {
		return groupComment{}, err
	}
	item := groupComment{
		ID: r.id.Int64, Post: r.post.Int64, Author: author, Parent: nullableInt(r.parent),
		Content: r.content.String, Likes: r.likes.Int64, Liked: r.liked.Int64 == 1,
		CanDelete: r.canDelete.Int64 == 1, Created: groupContentDate(r.created), Updated: groupContentDate(r.updated),
	}
	if r.reply.Valid && r.reply.Int64 != 0 {
		profile, err := readGroupPublicUser(ctx, db, viewer, r.reply.Int64, storage)
		if err != nil {
			return groupComment{}, err
		}
		item.ReplyTo = &profile
	}
	return item, nil
}

func (s OracleSessions) ReadGroupContent(ctx context.Context, viewer int64, req groupContentRequest, storage StorageURLPolicy) (any, int64, error) {
	return readGroupContent(ctx, s.DB, viewer, req, storage)
}

func readGroupContent(ctx context.Context, db groupDetailQueryer, viewer int64, req groupContentRequest, storage StorageURLPolicy) (any, int64, error) {
	query := groupContentPostsSQL
	option := "post_type"
	if req.comments {
		query = groupContentCommentsSQL
		option = "comment_sort"
	}
	binds := []any{
		sql.Named("viewer_id", viewer), sql.Named("group_id", req.group), sql.Named("post_id", req.post),
		sql.Named("start_row", req.page.Start), sql.Named("end_row", req.page.End), sql.Named(option, req.order),
	}
	if req.comments {
		binds = append(binds, sql.Named("target_comment_id", req.commentID))
	}
	rows, err := db.QueryContext(ctx, query, binds...)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	var allowed, postAllowed, total int64
	var posts []groupPostRow
	var comments []groupCommentRow
	for rows.Next() {
		if req.comments {
			var r groupCommentRow
			err = rows.Scan(append([]any{&allowed, &postAllowed, &total}, r.destinations()...)...)
			if r.id.Valid {
				comments = append(comments, r)
			}
		} else {
			var r groupPostRow
			err = rows.Scan(&allowed, &total,
				&r.id, &r.group, &r.author, &r.content, &r.media, &r.pinned, &r.announcement,
				&r.likes, &r.comments, &r.views, &r.created, &r.updated, &r.liked)
			if r.id.Valid {
				posts = append(posts, r)
			}
		}
		if err != nil {
			return nil, 0, errSessionStore
		}
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, 0, errSessionStore
	}
	if allowed != 1 {
		return nil, 0, errGroupDetailMissing
	}
	if req.post != 0 && (req.comments && postAllowed != 1 || !req.comments && len(posts) == 0) {
		return nil, 0, &groupMembershipFailure{404, "群组帖子不存在"}
	}
	if req.comments {
		items := make([]groupComment, 0, len(comments))
		for _, r := range comments {
			item, err := hydrateGroupComment(ctx, db, viewer, r, storage)
			if err != nil {
				return nil, 0, err
			}
			items = append(items, item)
		}
		return items, total, nil
	}
	items := make([]groupPost, 0, len(posts))
	for _, r := range posts {
		author, err := readGroupPublicUser(ctx, db, viewer, r.author.Int64, storage)
		if err != nil {
			return nil, 0, err
		}
		item := groupPost{
			ID: r.id.Int64, Group: r.group.Int64, Author: author, Content: r.content.String, Media: []string{},
			Pinned: r.pinned.Int64 == 1, Announcement: r.announcement.Int64 == 1, Likes: r.likes.Int64,
			Comments: r.comments.Int64, Views: r.views.Int64, Liked: r.liked.Int64 == 1,
			Created: groupContentDate(r.created), Updated: groupContentDate(r.updated),
		}
		for _, raw := range strings.Split(r.media.String, ",") {
			value := strings.TrimFunc(raw, jsTrimSpace)
			if value == "" {
				continue
			}
			value, err = normalizeAvatarURL(storage, value)
			if err != nil {
				return nil, 0, errSessionStore
			}
			item.Media = append(item.Media, value)
		}
		items = append(items, item)
	}
	if req.post != 0 {
		return items[0], total, nil
	}
	return items, total, nil
}

func groupContentDate(value sql.NullTime) string {
	if date := profileDate(value); date != nil {
		return *date
	}
	return ""
}

func groupContentRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	parts := strings.Split(path, "/")
	if r.Method != http.MethodGet || !ok || len(parts) < 2 || len(parts) > 4 ||
		parts[1] != "posts" || len(parts) == 4 && parts[3] != "comments" {
		return false
	}
	viewer, group, valid := interactionIdentity(w, r, codec, repo, parts[0])
	if !valid {
		return true
	}
	values := parseSessionQuery(r.URL.RawQuery)
	req := groupContentRequest{group: group, comments: len(parts) == 4, page: sessionPagination(values), order: "all"}
	if len(parts) >= 3 {
		id, valid := groupContentPostID(parts[2])
		if !valid {
			respond(w, 400, 40001, "post_id 参数错误", nil)
			return true
		}
		req.post = id
		if !req.comments {
			req.page.Start, req.page.End = 1, 1
		}
	}
	if req.comments {
		if ids, exists := values["comment_id"]; exists {
			if len(ids) != 1 || !publicID.MatchString(ids[0]) {
				respond(w, 400, 40001, "comment_id 参数错误", nil)
				return true
			}
			id, err := strconv.ParseInt(ids[0], 10, 64)
			if err != nil || id > maxSocketID {
				respond(w, 400, 40001, "comment_id 参数错误", nil)
				return true
			}
			req.commentID = id
			req.page = SessionPage{Page: 1, PageSize: 1, Start: 1, End: 1}
		}
		switch sort := getGroupFilter(values, "sort"); sort {
		case "":
			req.order = "newest"
		case "newest", "oldest", "popular":
			req.order = sort
		default:
			respond(w, 400, 40001, "sort 参数错误", nil)
			return true
		}
	} else if req.post == 0 {
		switch filter := getGroupFilter(values, "type"); filter {
		case "":
		case "all", "pinned", "announcement":
			req.order = filter
		default:
			respond(w, 400, 40001, "type 参数错误", nil)
			return true
		}
	}
	store, ok := repo.(groupContentStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	data, total, err := store.ReadGroupContent(r.Context(), viewer, req, storage)
	var failure *groupMembershipFailure
	switch {
	case errors.Is(err, errGroupDetailMissing):
		respond(w, 404, 40401, "群组不存在", nil)
	case errors.Is(err, errGroupMemberProfileMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case errors.As(err, &failure):
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		var meta any
		if req.comments || req.post == 0 {
			meta = map[string]any{"page": req.page.Page, "page_size": req.page.PageSize, "total": total, "has_next": req.page.End < float64(total)}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": data, "meta": meta})
	}
	return true
}

func groupContentPostID(value string) (int64, bool) {
	raw, err := url.PathUnescape(value)
	id, parseErr := strconv.ParseInt(raw, 10, 64)
	return id, err == nil && parseErr == nil && publicID.MatchString(raw) && id <= maxSocketID
}
