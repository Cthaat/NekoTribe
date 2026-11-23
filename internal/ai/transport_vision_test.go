package ai

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"testing"
)

func TestVisionTransportEncodesLastUserMessage(t *testing.T) {
	image := VisionImage{MIMEType: "image/jpeg", Data: []byte{0xff, 0xd8, 0xff, 1}}
	request := []byte(`{"messages":[{"role":"system","content":"system"},{"role":"user","content":"request"}]}`)
	for _, adapter := range []string{"openai-compatible", "ollama"} {
		t.Run(adapter, func(t *testing.T) {
			selection := Selection{Adapter: adapter, Capabilities: []string{"vision"}}
			encoded, _, _, err := encodeTransportWithImages(selection, request, false, []VisionImage{image})
			var body struct {
				Messages []map[string]any `json:"messages"`
			}
			if err != nil || json.Unmarshal(encoded, &body) != nil || len(body.Messages) != 2 || body.Messages[0]["content"] != "system" {
				t.Fatal(err, string(encoded))
			}
			last := body.Messages[1]
			base64Image := base64.StdEncoding.EncodeToString(image.Data)
			if adapter == "ollama" {
				images, ok := last["images"].([]any)
				if last["content"] != "request" || !ok || len(images) != 1 || images[0] != base64Image {
					t.Fatal(last)
				}
			} else {
				parts, _ := json.Marshal(last["content"])
				want := `[{"text":"request","type":"text"},{"image_url":{"url":"data:image/jpeg;base64,` + base64Image + `"},"type":"image_url"}]`
				if string(parts) != want {
					t.Fatal(string(parts))
				}
			}
		})
	}
	if _, _, _, err := encodeTransportWithImages(Selection{Adapter: "ollama"}, request, false, []VisionImage{image}); !errors.Is(err, ErrUnsupportedCapability) {
		t.Fatal(err)
	}
}
