package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"time"
)

type richMediaMetadata struct{ Width, Height, Duration *float64 }
type probeOptions struct {
	Binary     string
	PrefixArgs []string
}

var mediaProbeSlots = make(chan struct{}, 4)

func probeDimension(value *float64) *float64 {
	if value == nil || *value <= 0 || *value > 9007199254740991 || math.Trunc(*value) != *value {
		return nil
	}
	return value
}

func parseMediaProbe(data []byte) (richMediaMetadata, bool) {
	var payload struct {
		Streams []struct {
			CodecType     string `json:"codec_type"`
			Width, Height *float64
			Duration      string `json:"duration"`
		} `json:"streams"`
		Format struct {
			Duration string `json:"duration"`
		} `json:"format"`
	}
	if json.Unmarshal(data, &payload) != nil {
		return richMediaMetadata{}, false
	}
	var result richMediaMetadata
	var videoDuration, audioDuration string
	var videoSeen, audioSeen bool
	for _, stream := range payload.Streams {
		if stream.CodecType == "video" && !videoSeen {
			videoSeen = true
			result.Width, result.Height, videoDuration = probeDimension(stream.Width), probeDimension(stream.Height), stream.Duration
		}
		if stream.CodecType == "audio" && !audioSeen {
			audioSeen = true
			audioDuration = stream.Duration
		}
	}
	duration := payload.Format.Duration
	if duration == "" {
		duration = videoDuration
	}
	if duration == "" {
		duration = audioDuration
	}
	if value, err := strconv.ParseFloat(duration, 64); err == nil && value >= 0 && math.Round(value) <= 9007199254740991 {
		rounded := math.Round(value)
		result.Duration = &rounded
	}
	return result, true
}

type probeOutput struct {
	data     []byte
	exceeded bool
}

func (w *probeOutput) Write(p []byte) (int, error) {
	if len(p) > 65536-len(w.data) {
		w.exceeded = true
		return 0, errors.New("probe output limit")
	}
	w.data = append(w.data, p...)
	return len(p), nil
}

func probeMedia(parent context.Context, file *os.File, mimeType string, options probeOptions) richMediaMetadata {
	var format string
	switch mimeType {
	case "audio/wav":
		format = "wav"
	case "audio/mpeg":
		format = "mp3"
	case "audio/ogg", "video/ogg":
		format = "ogg"
	case "video/mp4":
		format = "mov"
	case "video/webm":
		format = "matroska"
	default:
		return richMediaMetadata{}
	}
	ctx, cancel := context.WithTimeout(parent, 8*time.Second)
	defer cancel()
	select {
	case mediaProbeSlots <- struct{}{}:
		defer func() { <-mediaProbeSlots }()
	case <-ctx.Done():
		return richMediaMetadata{}
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return richMediaMetadata{}
	}
	defer func() { _, _ = file.Seek(0, io.SeekStart) }()
	binary := options.Binary
	if binary == "" {
		binary = os.Getenv("FFPROBE_PATH")
	}
	if binary == "" {
		binary = "ffprobe"
	}
	input, protocols := "pipe:0", "pipe"
	switch runtime.GOOS {
	case "linux":
		input, protocols = "/proc/self/fd/0", "file,pipe"
	case "windows":
		// file is opened from the server's multipart staging directory.
		// A local path lets ffprobe seek back to samples after reading a tail index.
		path, err := filepath.Abs(file.Name())
		if err != nil {
			return richMediaMetadata{}
		}
		input, protocols = path, "file"
	}
	args := append([]string(nil), options.PrefixArgs...)
	if format == "mov" {
		args = append(args, "-enable_drefs", "0", "-use_absolute_path", "0")
	}
	args = append(args, "-v", "quiet", "-protocol_whitelist", protocols, "-f", format, "-print_format", "json", "-show_format", "-show_streams", "-i", input)
	command := exec.CommandContext(ctx, binary, args...)
	if runtime.GOOS != "windows" {
		command.Stdin = file
	}
	var output probeOutput
	command.Stdout = &output
	command.WaitDelay = time.Second
	if command.Run() != nil || output.exceeded {
		return richMediaMetadata{}
	}
	result, ok := parseMediaProbe(output.data)
	if !ok {
		return richMediaMetadata{}
	}
	return result
}
