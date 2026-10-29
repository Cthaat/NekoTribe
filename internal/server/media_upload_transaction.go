package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

var errMediaSchema = errors.New("media schema unavailable")

type mediaUploadInput struct {
	UserID, Size                                                        int64
	Key, PublicURL, FileName, MediaType, MIMEType, AltText, Description string
	Width, Height, Duration                                             *float64
	ThumbnailURL                                                        *string
}

// CleanupSafe only concerns the object created by this request. It becomes
// false once commit starts or when rollback cannot be confirmed.
type mediaUploadResult struct {
	Media       PostMedia
	CleanupSafe bool
}

func verifyMediaUploadSchema(ctx context.Context, conn *sql.Conn) error {
	var catalog schemaCatalog
	if json.Unmarshal(contracts.MediaSchemaCatalog, &catalog) != nil {
		return errMediaSchema
	}
	if validateFeatureSchema(ctx, conn, catalog, "media") != nil {
		return errMediaSchema
	}
	return nil
}

func (s OracleSessions) CreateMediaAtomic(ctx context.Context, input mediaUploadInput, policy StorageURLPolicy) (mediaUploadResult, error) {
	return s.createMediaAtomic(ctx, input, policy, verifyMediaUploadSchema)
}

func (s OracleSessions) createMediaAtomic(ctx context.Context, input mediaUploadInput, policy StorageURLPolicy, verify func(context.Context, *sql.Conn) error) (result mediaUploadResult, err error) {
	result.CleanupSafe = true
	if input.UserID <= 0 || input.Size <= 0 || input.Key == "" || input.PublicURL == "" {
		return result, errSessionStore
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return result, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			result.Media = PostMedia{}
			err = errSessionStore
		}
	}()
	var id int64
	if conn.QueryRowContext(ctx, `SELECT seq_media_id.NEXTVAL FROM dual`).Scan(&id) != nil || id <= 0 {
		return result, errSessionStore
	}
	if verify(ctx, conn) != nil {
		return result, errMediaSchema
	}
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return result, errSessionStore
	}
	result.CleanupSafe = false
	commitAttempted := false
	defer func() {
		if !commitAttempted {
			if e := tx.Rollback(); e == nil {
				result.CleanupSafe = true
			} else {
				result.CleanupSafe = false
				result.Media = PostMedia{}
				err = errSessionStore
			}
		}
	}()
	const insert = `INSERT INTO n_media_assets (media_id,owner_user_id,media_type,file_name,storage_key,public_url,file_size,mime_type,width,height,duration,thumbnail_url,alt_text,description,status) VALUES (:media_id,:owner_user_id,:media_type,:file_name,:storage_key,:public_url,:file_size,:mime_type,:width,:height,:duration,:thumbnail_url,:alt_text,:description,'ready')`
	inserted, e := tx.ExecContext(ctx, insert, sql.Named("media_id", id), sql.Named("owner_user_id", input.UserID), sql.Named("media_type", input.MediaType), sql.Named("file_name", input.FileName), sql.Named("storage_key", input.Key), sql.Named("public_url", input.PublicURL), sql.Named("file_size", input.Size), sql.Named("mime_type", input.MIMEType), sql.Named("width", input.Width), sql.Named("height", input.Height), sql.Named("duration", input.Duration), sql.Named("thumbnail_url", input.ThumbnailURL), sql.Named("alt_text", nullablePostString(input.AltText)), sql.Named("description", nullablePostString(input.Description)))
	if e != nil {
		return result, errSessionStore
	}
	count, e := inserted.RowsAffected()
	if e != nil || count != 1 {
		return result, errSessionStore
	}
	const read = `SELECT media_id,media_type,file_name,public_url,file_size,mime_type,width,height,duration,thumbnail_url,alt_text,description,status,created_at FROM n_media_assets WHERE media_id=:media_id`
	var media PostMedia
	var kind, name, public, mime, thumb, alt, description, status sql.NullString
	var size sql.NullInt64
	var width, height, duration sql.NullFloat64
	var created sql.NullTime
	if tx.QueryRowContext(ctx, read, sql.Named("media_id", id)).Scan(&media.MediaID, &kind, &name, &public, &size, &mime, &width, &height, &duration, &thumb, &alt, &description, &status, &created) != nil {
		return result, errSessionStore
	}
	media.MediaType = kind.String
	media.FileName = name.String
	media.FileSize = size.Int64
	media.MIMEType = mime.String
	media.Width = nullableFloat(width)
	media.Height = nullableFloat(height)
	media.Duration = nullableFloat(duration)
	media.AltText = nullableString(alt)
	media.Description = nullableString(description)
	media.Status = status.String
	media.PublicURL, e = normalizeAvatarURL(policy, public.String)
	if e != nil {
		return result, errSessionStore
	}
	if thumb.Valid && thumb.String != "" {
		value, e := normalizeAvatarURL(policy, thumb.String)
		if e != nil {
			return result, errSessionStore
		}
		media.ThumbnailURL = &value
	}
	if date := profileDate(created); date != nil {
		media.CreatedAt = *date
	}
	commitAttempted = true
	if tx.Commit() != nil {
		return result, errSessionStore
	}
	result.Media = media
	return result, nil
}
