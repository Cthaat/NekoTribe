package ai

import (
	"encoding/base64"
	"net/http"
)

const (
	MaxVisionImages     = 4
	MaxVisionImageBytes = 4 << 20
	MaxVisionTotalBytes = 8 << 20
)

// VisionImage holds bytes already read from authorized server-side storage.
type VisionImage struct {
	MIMEType string
	Data     []byte
}

func IsVisionImageType(mime string) bool {
	return mime == "image/jpeg" || mime == "image/png" || mime == "image/webp"
}

func (image VisionImage) Valid() bool {
	return len(image.Data) > 0 && len(image.Data) <= MaxVisionImageBytes && IsVisionImageType(image.MIMEType) && http.DetectContentType(image.Data) == image.MIMEType
}

func attachVisionImages(selection Selection, messages []any, images []VisionImage) (int, error) {
	if len(images) == 0 {
		return 0, nil
	}
	if !contains(selection.Capabilities, "vision") {
		return 0, ErrUnsupportedCapability
	}
	last, ok := transportObject(messages[len(messages)-1])
	if !ok || last["role"] != "user" || len(images) > MaxVisionImages {
		return 0, ErrInvalidRequest
	}
	var total, encodedBytes int
	for _, image := range images {
		if !image.Valid() || total+len(image.Data) > MaxVisionTotalBytes {
			return 0, ErrInvalidRequest
		}
		total += len(image.Data)
		encodedBytes += base64.StdEncoding.EncodedLen(len(image.Data))
	}
	if selection.Adapter == "ollama" {
		encoded := make([]string, 0, len(images))
		for _, image := range images {
			encoded = append(encoded, base64.StdEncoding.EncodeToString(image.Data))
		}
		last["images"] = encoded
	} else {
		parts := []map[string]any{{"type": "text", "text": last["content"]}}
		for _, image := range images {
			parts = append(parts, map[string]any{"type": "image_url", "image_url": map[string]string{
				"url": "data:" + image.MIMEType + ";base64," + base64.StdEncoding.EncodeToString(image.Data),
			}})
		}
		last["content"] = parts
	}
	return encodedBytes + 1024, nil
}
