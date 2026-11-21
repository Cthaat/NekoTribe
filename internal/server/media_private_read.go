package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var privateMediaReadQuery = func() string {
	var spec struct {
		Query string `json:"query"`
	}
	if err := json.Unmarshal(contracts.MediaPrivateRead, &spec); err != nil || strings.TrimSpace(spec.Query) == "" {
		panic("invalid private media read contract")
	}
	return spec.Query
}()

type privateMediaReader interface {
	ReadPrivateMedia(context.Context, int64, int64) (key, scope string, err error)
}

func (s OracleSessions) ReadPrivateMedia(ctx context.Context, viewer, media int64) (string, string, error) {
	var key, scope sql.NullString
	err := s.DB.QueryRowContext(ctx, privateMediaReadQuery, sql.Named("viewer_id", viewer), sql.Named("media_id", media)).Scan(&key, &scope)
	return key.String, scope.String, err
}

func privateMediaContentSegment(path string) (string, bool) {
	path, ok := strings.CutSuffix(path, "/content")
	if !ok {
		return "", false
	}
	return mediaSegment(path)
}

func privateMediaContentPath(id int64) string {
	return "/api/v2/media/" + strconv.FormatInt(id, 10) + "/content"
}

func normalizePrivateMediaStorageKey(raw, scope string) (string, error) {
	key, err := normalizeLocalFileKey(raw)
	if err != nil || (scope != "chat" && scope != "post") || !strings.HasPrefix(key, "private/"+scope+"/") {
		return "", errLocalFileKey
	}
	return key, nil
}

func privateMediaSchemaMissing(err error) bool {
	var oracleErr interface{ ErrorCode() string }
	if errors.As(err, &oracleErr) {
		return oracleErr.ErrorCode() == "ORA-00904" || oracleErr.ErrorCode() == "ORA-00942"
	}
	return strings.HasPrefix(err.Error(), "ORA-00904:") || strings.HasPrefix(err.Error(), "ORA-00942:")
}

func respondPrivateMediaError(w http.ResponseWriter, status int) {
	switch status {
	case http.StatusNotFound:
		respond(w, status, 40401, "媒体不存在", nil)
	case http.StatusRequestedRangeNotSatisfiable:
		respond(w, status, 41601, "请求范围无效", nil)
	case http.StatusServiceUnavailable:
		respond(w, status, 50301, "媒体存储暂不可用", nil)
	default:
		respond(w, http.StatusInternalServerError, 50001, "服务器内部错误", nil)
	}
}

func readPrivateMediaContent(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config LocalStorageConfig, raw string) {
	viewer, media, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	if viewer <= 0 || viewer > 9007199254740991 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	store, ok := repository.(privateMediaReader)
	if !ok {
		respondPrivateMediaError(w, http.StatusServiceUnavailable)
		return
	}
	rawKey, scope, err := store.ReadPrivateMedia(r.Context(), viewer, media)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		if privateMediaSchemaMissing(err) {
			respondPrivateMediaError(w, http.StatusServiceUnavailable)
		} else {
			respondPrivateMediaError(w, http.StatusInternalServerError)
		}
		return
	}
	key, keyErr := normalizePrivateMediaStorageKey(rawKey, scope)
	if err != nil || keyErr != nil {
		respondPrivateMediaError(w, http.StatusNotFound)
		return
	}
	if config.Unsupported {
		respondPrivateMediaError(w, http.StatusServiceUnavailable)
		return
	}
	serveStorageObject(w, r, config, key, true)
}
