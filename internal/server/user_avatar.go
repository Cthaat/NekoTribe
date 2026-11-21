package server

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type avatarSpec struct {
	MaxFileBytes, MaxFieldBytes int64
	MaxFiles, MaxFields         int
	Formats                     []struct {
		Hex, MIME, Extension string
		prefix               []byte
	}
	SQL map[string]string
}

var avatarContract = func() avatarSpec {
	var spec avatarSpec
	if err := json.Unmarshal(contracts.UserAvatarContract, &spec); err != nil {
		panic("invalid avatar contract")
	}
	for i := range spec.Formats {
		var err error
		spec.Formats[i].prefix, err = hex.DecodeString(spec.Formats[i].Hex)
		if err != nil {
			panic("invalid avatar signature")
		}
	}
	return spec
}()

type avatarStore interface {
	ReplaceUserAvatar(context.Context, mediaUploadInput) (int64, bool, error)
}

func (s OracleSessions) ReplaceUserAvatar(ctx context.Context, input mediaUploadInput) (id int64, cleanupSafe bool, err error) {
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return 0, true, errSessionStore
	}
	commitStarted := false
	defer func() {
		if !commitStarted {
			cleanupSafe = tx.Rollback() == nil
		}
	}()
	user := sql.Named("user_id", input.UserID)
	var locked int64
	if tx.QueryRowContext(ctx, avatarContract.SQL["lock"], user).Scan(&locked) != nil || locked != input.UserID ||
		tx.QueryRowContext(ctx, avatarContract.SQL["next"]).Scan(&id) != nil || id <= 0 || id > 9007199254740991 {
		return 0, false, errSessionStore
	}
	reference := []any{user, sql.Named("media_id", id), sql.Named("public_url", input.PublicURL)}
	result, e := tx.ExecContext(ctx, avatarContract.SQL["insert"], append(reference, sql.Named("file_name", input.FileName),
		sql.Named("storage_key", input.Key), sql.Named("file_size", input.Size), sql.Named("mime_type", input.MIMEType))...)
	if e != nil {
		return 0, false, errSessionStore
	}
	count, e := result.RowsAffected()
	if e != nil || count != 1 {
		return 0, false, errSessionStore
	}
	result, e = tx.ExecContext(ctx, avatarContract.SQL["update"], reference...)
	if e != nil {
		return 0, false, errSessionStore
	}
	count, e = result.RowsAffected()
	if e != nil || count != 1 {
		return 0, false, errSessionStore
	}
	commitStarted = true
	if tx.Commit() != nil {
		return 0, false, errSessionStore
	}
	return id, false, nil
}

func uploadUserAvatar(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	store, ok := repository.(avatarStore)
	if !ok {
		serverError()
		return
	}
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || contentType != "multipart/form-data" {
		respond(w, 400, 40001, "请使用 multipart/form-data 上传头像", nil)
		return
	}
	if config.LocalStorage.Unsupported {
		respond(w, http.StatusServiceUnavailable, 50301, "媒体存储暂不可用", nil)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, avatarContract.MaxFileBytes+avatarContract.MaxFieldBytes+(10<<20))
	limits := mediaMultipartLimits{fileBytes: avatarContract.MaxFileBytes, totalBytes: avatarContract.MaxFileBytes,
		fieldBytes: avatarContract.MaxFieldBytes, files: avatarContract.MaxFiles, fields: avatarContract.MaxFields}
	media, err := parseMediaMultipartWithAlias(r, config.LocalStorage, limits, "avatar")
	if err != nil {
		switch {
		case errors.Is(err, errMediaNoFile):
			respond(w, 400, 40001, "上传文件为空", nil)
		case errors.Is(err, errMediaMultipart):
			respond(w, 400, 40001, "头像上传失败", nil)
		default:
			serverError()
		}
		return
	}
	defer func() {
		if media.Close() != nil {
			log.Print("avatar temporary cleanup failed")
		}
	}()
	source, err := media.OpenSelected()
	if err != nil {
		serverError()
		return
	}
	var data [8]byte
	size, err := io.ReadFull(source, data[:])
	closeErr := source.Close()
	if (err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF)) || closeErr != nil {
		serverError()
		return
	}
	format, mimeType := "", ""
	for _, candidate := range avatarContract.Formats {
		if bytes.HasPrefix(data[:size], candidate.prefix) {
			format, mimeType = candidate.Extension, candidate.MIME
			break
		}
	}
	if format == "" {
		respond(w, 400, 40001, "头像仅支持 jpg、png、gif 图片", nil)
		return
	}
	name := media.Selected.Name
	if name == "" || len(name) > 255 || strings.ContainsAny(name, "/\\") || strings.ContainsFunc(name, func(r rune) bool { return r < 32 || r == 127 }) {
		name = "avatar" + format
	}
	id, err := randomUUID()
	if err != nil {
		serverError()
		return
	}
	now := config.clock().UTC()
	key := fmt.Sprintf("avatars/%d/%04d/%02d/%s%s", user, now.Year(), now.Month(), id, format)
	url, err := normalizeAvatarURL(config.Storage, "/storage/"+key)
	if err != nil {
		serverError()
		return
	}
	cleanup, release, err := publishRouteMedia(r.Context(), media, config.LocalStorage, key, mimeType)
	if err != nil {
		serverError()
		return
	}
	defer release()
	mediaID, cleanupSafe, err := store.ReplaceUserAvatar(r.Context(), mediaUploadInput{UserID: user, Size: media.Selected.Size, Key: key, PublicURL: url, FileName: name, MIMEType: mimeType})
	if err != nil {
		if cleanupSafe && cleanup() != nil {
			log.Print("avatar rollback storage cleanup failed")
		}
		serverError()
		return
	}
	respond(w, 200, 200, "success", map[string]any{"avatar_url": url, "avatar_media_id": mediaID})
}
