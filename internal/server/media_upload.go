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

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	_ "golang.org/x/image/webp"
)

type mediaUploadStore interface {
	CreateMediaAtomic(context.Context, mediaUploadInput, StorageURLPolicy) (mediaUploadResult, error)
}

func uploadMedia(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
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
	media, err := parseMediaMultipart(r, config.LocalStorage, defaultMediaMultipartLimits)
	if err != nil {
		switch {
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
	if config.LocalStorage.Unsupported {
		respond(w, 501, 50101, "媒体存储暂不可用", nil)
		return
	}
	key, err := newMediaObjectKey(user, selected.MediaType, selected.Extension, config.clock())
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	publicURL, err := normalizeAvatarURL(config.Storage, "/storage/"+key)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	var identity *mediaObjectIdentity
	if err = saveMediaObjectWithIdentity(r.Context(), media, config.LocalStorage, key, &identity); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	defer func() {
		if identity != nil && identity.file.Close() != nil {
			log.Print("media upload object handle close unavailable")
		}
	}()
	input := mediaUploadInput{UserID: user, Size: media.Selected.Size, Key: key, PublicURL: publicURL, FileName: name, MediaType: selected.MediaType, MIMEType: selected.MIMEType, AltText: media.AltText, Description: media.Description, Width: width, Height: height, Duration: duration}
	result, err := store.CreateMediaAtomic(r.Context(), input, config.Storage)
	if err != nil {
		if result.CleanupSafe {
			if cleanupPublishedMedia(media, key, identity) != nil {
				log.Print("media upload object cleanup unavailable")
			}
		}
		if errors.Is(err, errMediaSchema) {
			respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		} else {
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return
	}
	respond(w, 200, 200, "media uploaded", result.Media)
}
