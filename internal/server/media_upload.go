package server

import (
	"context"
	"errors"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	_ "golang.org/x/image/webp"
)

type mediaUploadStore interface {
	CreateMediaAtomic(context.Context, mediaUploadInput, StorageURLPolicy) (mediaUploadResult, error)
}

type privateMediaUploadSchemaChecker interface {
	CheckPrivateMediaUploadSchema(context.Context) error
}

const mediaUploadBodyTimeout = 15 * time.Minute
const mediaUploadResponseGrace = 6 * time.Minute

func uploadMedia(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, requirePrivate bool) {
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	store, ok := repository.(mediaUploadStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	typ, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || !strings.EqualFold(typ, "multipart/form-data") {
		respond(w, 400, 40001, "请使用 multipart/form-data 上传媒体文件", nil)
		return
	}
	deadline := time.Now().Add(mediaUploadBodyTimeout)
	response := http.NewResponseController(w)
	_ = response.SetReadDeadline(deadline)
	_ = response.SetWriteDeadline(deadline.Add(mediaUploadResponseGrace))
	media, err := parseMediaMultipartRequest(r, config.LocalStorage, defaultMediaMultipartLimits, "media", requirePrivate)
	if err != nil {
		switch {
		case errors.Is(err, errMediaAccessScope):
			respond(w, 400, 40001, "媒体访问范围无效", nil)
		case errors.Is(err, errMediaNoFile):
			respond(w, 400, 40001, "上传文件为空", nil)
		case errors.Is(err, errMediaMultipart):
			respond(w, 400, 40001, "媒体上传失败", nil)
		default:
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return
	}
	defer func() {
		if media.Close() != nil {
			log.Print("media upload temporary cleanup unavailable")
		}
	}()
	if len(media.AltText) > 500 || len(media.Description) > 1000 {
		respond(w, 400, 40001, "媒体替代文本或描述过长", nil)
		return
	}
	file, err := media.OpenSelected()
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	info, statErr := file.Stat()
	var detected *mediaDetectedType
	if statErr == nil && info.Mode().IsRegular() && info.Size() == media.Selected.Size {
		detected, err = detectMediaFile(r.Context(), file, info.Size())
	} else {
		err = errMediaStorage
	}
	var width, height, duration *float64
	if err == nil {
		selected := selectMediaFileType(media.Selected.Name, media.Selected.MIME, detected)
		if selected.Supported && (selected.MediaType == "image" || selected.MediaType == "gif") {
			if imageInfo, _, decodeErr := image.DecodeConfig(io.NewSectionReader(file, 0, min(info.Size(), int64(4<<20)))); decodeErr == nil {
				w, h := float64(imageInfo.Width), float64(imageInfo.Height)
				width, height = &w, &h
			} else if selected.MIMEType == "image/avif" {
				prefix, readErr := io.ReadAll(io.NewSectionReader(file, 0, min(info.Size(), int64(4<<20))))
				if readErr == nil {
					if iw, ih, ok := avifDimensions(prefix); ok {
						w, h := float64(iw), float64(ih)
						width, height = &w, &h
					}
				}
			}
		}
		if selected.Supported && !config.LocalStorage.Unsupported && (selected.MediaType == "video" || selected.MediaType == "audio") {
			metadata := probeMedia(r.Context(), file, selected.MIMEType, probeOptions{})
			width, height, duration = metadata.Width, metadata.Height, metadata.Duration
			if duration == nil && selected.MIMEType == "audio/wav" {
				duration = pcmWAVDuration(file)
			}
		}
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	name := media.Selected.Name
	if name == "" {
		name = media.Selected.path
	}
	selected := selectMediaFileType(name, media.Selected.MIME, detected)
	if !selected.Supported {
		respond(w, 400, 40001, "仅支持图片、视频、音频、文档、文本或压缩包文件", nil)
		return
	}
	private := media.AccessScope != ""
	if private {
		checker, ok := repository.(privateMediaUploadSchemaChecker)
		if config.LocalStorage.Unsupported || !ok || checker.CheckPrivateMediaUploadSchema(r.Context()) != nil {
			respondPrivateMediaError(w, http.StatusServiceUnavailable)
			return
		}
	} else if config.LocalStorage.Unsupported {
		respond(w, http.StatusServiceUnavailable, 50301, "媒体存储暂不可用", nil)
		return
	}
	key, err := newMediaObjectKey(user, selected.MediaType, selected.Extension, config.clock())
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	var publicURL string
	if private {
		key = "private/" + media.AccessScope + "/" + strings.TrimPrefix(key, "posts/")
	} else {
		publicURL, err = normalizeAvatarURL(config.Storage, "/storage/"+key)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
	}
	cleanup, release, err := publishRouteMedia(r.Context(), media, config.LocalStorage, key, selected.MIMEType)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	defer release()
	input := mediaUploadInput{UserID: user, Size: media.Selected.Size, Key: key, PublicURL: publicURL, AccessScope: media.AccessScope, FileName: name, MediaType: selected.MediaType, MIMEType: selected.MIMEType, AltText: media.AltText, Description: media.Description, Width: width, Height: height, Duration: duration}
	result, err := store.CreateMediaAtomic(r.Context(), input, config.Storage)
	if err != nil {
		if result.CleanupSafe {
			if cleanup() != nil {
				log.Print("media upload object cleanup unavailable")
			}
		}
		if errors.Is(err, errMediaSchema) {
			if private {
				respondPrivateMediaError(w, http.StatusServiceUnavailable)
			} else {
				respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
			}
		} else {
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return
	}
	respond(w, 200, 200, "media uploaded", result.Media)
}
