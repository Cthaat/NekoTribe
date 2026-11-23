package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type mediaDeleteRecord struct {
	Deleted                      bool
	Key, PublicURL, ThumbnailURL string
}

var errMediaInUse = errors.New("media in use")

type mediaReferenceContract struct {
	CheckReferences   string `json:"checkReferences"`
	KeyPattern        string `json:"keyPattern"`
	AliasPattern      string `json:"aliasPattern"`
	LookupGroupImages string `json:"lookupGroupImages"`
	LockGroupImage    string `json:"lockGroupImage"`
}

var mediaReferences = func() mediaReferenceContract {
	var spec mediaReferenceContract
	if err := json.Unmarshal(contracts.MediaDeleteReferences, &spec); err != nil ||
		spec.CheckReferences == "" || spec.KeyPattern == "" || spec.AliasPattern == "" ||
		spec.LookupGroupImages == "" || spec.LockGroupImage == "" {
		panic("invalid media delete reference contract")
	}
	return spec
}()

var groupImageAlias = regexp.MustCompile(mediaReferences.AliasPattern)
var groupImageKey = regexp.MustCompile(mediaReferences.KeyPattern)

func managedGroupImageKey(policy StorageURLPolicy, reference string) string {
	url := strings.TrimFunc(reference, jsTrimSpace)
	var key string
	if alias := groupImageAlias.FindStringSubmatch(url); alias != nil {
		key = alias[3]
	} else {
		if end := strings.IndexAny(url, "?#"); end >= 0 {
			url = url[:end]
		}
		key, _ = mediaManagedKey(policy, url)
	}
	if groupImageKey.MatchString(key) {
		return key
	}
	return ""
}

type mediaDeleteStore interface {
	DeleteMedia(context.Context, int64, float64) (mediaDeleteRecord, error)
}

func mediaSegment(path string) (string, bool) {
	const prefix = "/api/v2/media/"
	if !strings.HasPrefix(path, prefix) {
		return "", false
	}
	id := strings.TrimPrefix(path, prefix)
	return id, id != "" && !strings.Contains(id, "/")
}

func deleteMedia(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	decoded, err := url.PathUnescape(raw)
	id, valid := postNullableNumber(decoded)
	if err != nil || !valid || id <= 0 {
		respond(w, 400, 40001, "id 参数错误", nil)
		return
	}
	store, ok := repository.(mediaDeleteStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	record, err := store.DeleteMedia(r.Context(), user, id)
	if errors.Is(err, errMediaInUse) {
		respond(w, 409, 40901, "媒体正在使用", nil)
		return
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !record.Deleted {
		respond(w, 404, 40401, "媒体不存在", nil)
		return
	}
	if err = deleteMediaReference(config.LocalStorage, config.Storage, record.Key, record.PublicURL); err == nil {
		err = deleteMediaReference(config.LocalStorage, config.Storage, "", record.ThumbnailURL)
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "media deleted", nil)
}

func (s OracleSessions) DeleteMedia(ctx context.Context, user int64, id float64) (mediaDeleteRecord, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return mediaDeleteRecord{}, errSessionStore
	}
	defer tx.Rollback()
	const read = `SELECT storage_key, public_url, thumbnail_url FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id FOR UPDATE`
	var key, public, thumbnail sql.NullString
	mediaID := sql.Named("media_id", id)
	owner := sql.Named("user_id", user)
	err = tx.QueryRowContext(ctx, read, mediaID, owner).Scan(&key, &public, &thumbnail)
	if errors.Is(err, sql.ErrNoRows) {
		return mediaDeleteRecord{}, nil
	}
	if err != nil {
		return mediaDeleteRecord{}, errSessionStore
	}
	var inUse int
	err = tx.QueryRowContext(ctx, mediaReferences.CheckReferences, mediaID).Scan(&inUse)
	if err == nil {
		return mediaDeleteRecord{}, errMediaInUse
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return mediaDeleteRecord{}, errSessionStore
	}
	linked, err := directAssetLinked(ctx, tx, mediaID)
	if err != nil {
		return mediaDeleteRecord{}, err
	}
	if linked {
		return mediaDeleteRecord{}, errMediaInUse
	}
	const remove = `DELETE FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id`
	count, err := postTxExecute(ctx, tx, remove, mediaID, owner)
	if err != nil {
		return mediaDeleteRecord{}, errSessionStore
	}
	if count == 0 {
		return mediaDeleteRecord{}, nil
	}
	if count != 1 || tx.Commit() != nil {
		return mediaDeleteRecord{}, errSessionStore
	}
	return mediaDeleteRecord{Deleted: true, Key: key.String, PublicURL: public.String, ThumbnailURL: thumbnail.String}, nil
}

func mediaManagedKey(policy StorageURLPolicy, reference string) (string, error) {
	if reference == "" {
		return "", nil
	}
	if policy.invalidPublicBase || hasStorageCredentials(policy) {
		return "", errLocalFileKey
	}
	basePath := policy.PublicBase
	if basePath == "" {
		basePath = "/storage"
	}
	prefixes := []string{basePath + "/", "/storage/", "/uploads/", "/upload/"}
	find := func(value string) (string, error) {
		for _, prefix := range prefixes {
			if strings.HasPrefix(value, prefix) {
				return normalizeLocalFileKey(strings.TrimPrefix(value, prefix))
			}
		}
		return "", nil
	}
	if strings.HasPrefix(reference, "/") {
		return find(reference)
	}
	base := policy.CDNBaseURL
	if base == "" {
		base = policy.BaseURL
	}
	if base == "" {
		return "", nil
	}
	parsed, err := url.Parse(reference)
	if err != nil {
		return "", nil
	}
	origin, err := url.Parse(base + "/")
	if err != nil || !sameURLOrigin(parsed, origin) {
		return "", nil
	}
	return find(parsed.EscapedPath())
}

func deleteMediaReference(config LocalStorageConfig, policy StorageURLPolicy, storageKey, reference string) error {
	key := storageKey
	if key == "" {
		var err error
		key, err = mediaManagedKey(policy, reference)
		if err != nil || key == "" {
			return err
		}
	}
	key, err := normalizeLocalFileKey(key)
	if err != nil {
		return err
	}
	prefix, _, _ := strings.Cut(key, "/")
	if strings.EqualFold(prefix, "private") && storageKey == "" {
		return nil
	}
	if strings.EqualFold(prefix, "temp") || (strings.EqualFold(prefix, "private") && !isPrivateStorageKey(key)) {
		return errLocalFileKey
	}
	if config.Unsupported {
		return errors.New("storage unavailable")
	}
	if config.s3 != nil {
		return config.s3.delete(context.Background(), key)
	}
	rootPath := config.Root
	if rootPath == "" {
		rootPath = "./storage"
	}
	root, err := os.OpenRoot(rootPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer root.Close()
	parts := strings.Split(key, "/")
	for i := range parts {
		info, err := root.Lstat(filepath.Join(parts[:i+1]...))
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || (i < len(parts)-1 && !info.IsDir()) || (i == len(parts)-1 && !info.Mode().IsRegular()) {
			return errLocalFileKey
		}
	}
	err = root.Remove(filepath.FromSlash(key))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
