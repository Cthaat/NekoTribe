package server

import (
	"context"
	"database/sql"
	"errors"
)

const postDetailSQL = `SELECT v.post_id,v.author_id,DBMS_LOB.SUBSTR(v.content,4000,1),v.post_type,v.visibility,v.language,v.location,v.reply_to_post_id,v.repost_of_post_id,v.quoted_post_id,v.likes_count,v.comments_count,v.replies_count,v.retweets_count,v.views_count,v.engagement_score,CASE WHEN EXISTS (SELECT 1 FROM n_post_likes pl WHERE pl.post_id=v.post_id AND pl.user_id=:viewer_id) THEN 1 ELSE 0 END,CASE WHEN EXISTS (SELECT 1 FROM n_post_bookmarks pb WHERE pb.post_id=v.post_id AND pb.user_id=:viewer_id) THEN 1 ELSE 0 END,v.created_at,v.updated_at FROM v_post_feed_item v WHERE fn_can_view_post(:viewer_id,v.post_id)=1 AND v.post_id=:post_id`
const postMediaSQL = `SELECT ma.media_id,ma.media_type,ma.file_name,ma.public_url,ma.file_size,ma.mime_type,ma.width,ma.height,ma.duration,ma.thumbnail_url,ma.alt_text,ma.description,ma.status,ma.created_at FROM n_post_media pm JOIN n_media_assets ma ON ma.media_id=pm.media_id WHERE pm.post_id=:post_id ORDER BY pm.sort_order`
const postTagsSQL = `SELECT t.name FROM n_post_tags pt JOIN n_tags t ON t.tag_id=pt.tag_id WHERE pt.post_id=:post_id ORDER BY t.name`
const postMentionsSQL = `SELECT u.user_id,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,fn_get_user_relationship(:viewer_id,u.user_id) AS relation FROM n_post_mentions pm JOIN v_user_profile_public u ON u.user_id=pm.mentioned_user_id WHERE pm.post_id=:post_id ORDER BY u.username`
const incrementPostViewsSQL = `UPDATE n_post_stats SET views_count=views_count+1,updated_at=CURRENT_TIMESTAMP WHERE post_id=:post_id`

func nullableViewer(v *int64) any {
	if v == nil {
		return nil
	}
	return *v
}
func nullableInt(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	return &v.Int64
}
func nullableFloat(v sql.NullFloat64) *float64 {
	if !v.Valid {
		return nil
	}
	return &v.Float64
}
func nullableString(v sql.NullString) *string {
	if !v.Valid || v.String == "" {
		return nil
	}
	return &v.String
}

type scannerWithExtra struct {
	row   interface{ Scan(...any) error }
	extra []any
}

func (s scannerWithExtra) Scan(values ...any) error {
	return s.row.Scan(append(values, s.extra...)...)
}
func scanPostWithExtra(row interface{ Scan(...any) error }, viewer *int64, extra ...any) (PostDetail, bool, error) {
	return scanPost(scannerWithExtra{row: row, extra: extra}, viewer)
}
func scanPost(row interface{ Scan(...any) error }, viewer *int64) (PostDetail, bool, error) {
	var p PostDetail
	var author int64
	var content, kind, visibility, language, location sql.NullString
	var reply, repost, quoted sql.NullInt64
	var likes, comments, replies, retweets, views, score sql.NullFloat64
	var liked, bookmark sql.NullInt64
	var created, updated sql.NullTime
	err := row.Scan(&p.PostID, &author, &content, &kind, &visibility, &language, &location, &reply, &repost, &quoted, &likes, &comments, &replies, &retweets, &views, &score, &liked, &bookmark, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return PostDetail{}, false, nil
	}
	if err != nil {
		return PostDetail{}, false, errSessionStore
	}
	p.Author.UserID = author
	p.Content = content.String
	p.PostType = kind.String
	p.Visibility = visibility.String
	p.Language = language.String
	p.Location = location.String
	p.ReplyToPostID = nullableInt(reply)
	p.RepostOfPostID = nullableInt(repost)
	p.QuotedPostID = nullableInt(quoted)
	p.Stats = PostStats{LikesCount: likes.Float64, CommentsCount: comments.Float64, RepliesCount: replies.Float64, RetweetsCount: retweets.Float64, ViewsCount: views.Float64, EngagementScore: score.Float64}
	p.ViewerState = PostViewerState{IsLiked: liked.Int64 == 1, IsBookmarked: bookmark.Int64 == 1, CanDelete: viewer != nil && *viewer == author}
	if d := profileDate(created); d != nil {
		p.CreatedAt = *d
	}
	if d := profileDate(updated); d != nil {
		p.UpdatedAt = *d
	}
	return p, true, nil
}
func (s OracleSessions) ReadVisiblePost(ctx context.Context, viewer *int64, id int64) (PostDetail, bool, error) {
	row := s.DB.QueryRowContext(ctx, postDetailSQL, sql.Named("viewer_id", nullableViewer(viewer)), sql.Named("post_id", id))
	return scanPost(row, viewer)
}
func (s OracleSessions) ReadPostAuthor(ctx context.Context, viewer *int64, id int64) (PublicUser, bool, error) {
	return s.publicProfile(ctx, nullableViewer(viewer), id)
}
func (s OracleSessions) ReadPostMedia(ctx context.Context, id int64) ([]PostMedia, error) {
	rows, err := s.DB.QueryContext(ctx, postMediaSQL, sql.Named("post_id", id))
	if err != nil {
		return nil, errSessionStore
	}
	items := []PostMedia{}
	for rows.Next() {
		var p PostMedia
		var kind, name, public, mime, thumb, alt, desc, status sql.NullString
		var size sql.NullInt64
		var width, height, duration sql.NullFloat64
		var created sql.NullTime
		if rows.Scan(&p.MediaID, &kind, &name, &public, &size, &mime, &width, &height, &duration, &thumb, &alt, &desc, &status, &created) != nil {
			_ = rows.Close()
			return nil, errSessionStore
		}
		p.MediaType = kind.String
		p.FileName = name.String
		p.PublicURL = public.String
		p.FileSize = size.Int64
		p.MIMEType = mime.String
		p.Width = nullableFloat(width)
		p.Height = nullableFloat(height)
		p.Duration = nullableFloat(duration)
		p.ThumbnailURL = nullableString(thumb)
		p.AltText = nullableString(alt)
		p.Description = nullableString(desc)
		p.Status = status.String
		if d := profileDate(created); d != nil {
			p.CreatedAt = *d
		}
		items = append(items, p)
	}
	readErr := rows.Err()
	closeErr := rows.Close()
	if readErr != nil || closeErr != nil {
		return nil, errSessionStore
	}
	return items, nil
}
func (s OracleSessions) ReadPostTags(ctx context.Context, id int64) ([]string, error) {
	rows, err := s.DB.QueryContext(ctx, postTagsSQL, sql.Named("post_id", id))
	if err != nil {
		return nil, errSessionStore
	}
	items := []string{}
	for rows.Next() {
		var name sql.NullString
		if rows.Scan(&name) != nil {
			_ = rows.Close()
			return nil, errSessionStore
		}
		items = append(items, name.String)
	}
	readErr := rows.Err()
	closeErr := rows.Close()
	if readErr != nil || closeErr != nil {
		return nil, errSessionStore
	}
	return items, nil
}
func (s OracleSessions) ReadPostMentions(ctx context.Context, viewer *int64, id int64) ([]PublicUser, error) {
	rows, err := s.DB.QueryContext(ctx, postMentionsSQL, sql.Named("viewer_id", nullableViewer(viewer)), sql.Named("post_id", id))
	if err != nil {
		return nil, errSessionStore
	}
	items := []PublicUser{}
	for rows.Next() {
		var v PublicUser
		var username, avatar, display, bio, location, website, relation sql.NullString
		var verified, followers, following, posts, likes sql.NullInt64
		if rows.Scan(&v.UserID, &username, &avatar, &display, &bio, &location, &website, &verified, &followers, &following, &posts, &likes, &relation) != nil {
			_ = rows.Close()
			return nil, errSessionStore
		}
		v.Username = username.String
		v.AvatarURL = avatar.String
		v.DisplayName = display.String
		v.Bio = bio.String
		v.Location = location.String
		v.Website = website.String
		v.IsVerified = verified.Int64
		v.FollowersCount = followers.Int64
		v.FollowingCount = following.Int64
		v.PostsCount = posts.Int64
		v.LikesCount = likes.Int64
		rel := relation.String
		if !relation.Valid {
			rel = "none"
		}
		v.Relationship = SelfRelationship{IsSelf: rel == "self", IsFollowing: rel == "following" || rel == "mutual_follow", IsBlocked: rel == "blocked_by", IsBlocking: rel == "blocking", Relation: rel}
		v.OnlineStatus = "offline"
		items = append(items, v)
	}
	readErr := rows.Err()
	closeErr := rows.Close()
	if readErr != nil || closeErr != nil {
		return nil, errSessionStore
	}
	return items, nil
}
func (s OracleSessions) IncrementPostViews(ctx context.Context, id int64) error {
	_, err := s.execute(ctx, incrementPostViewsSQL, sql.Named("post_id", id))
	return err
}
