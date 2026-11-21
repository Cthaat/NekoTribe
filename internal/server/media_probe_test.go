package server

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestMediaProbeMapping(t *testing.T) {
	sample := []byte(`{"streams":[{"codec_type":"audio","duration":"5.2"},{"codec_type":"video","width":640,"height":360,"duration":"9.2"}],"format":{"duration":"12.5"}}`)
	result, ok := parseMediaProbe(sample)
	if !ok || result.Width == nil || *result.Width != 640 || result.Height == nil || *result.Height != 360 || result.Duration == nil || *result.Duration != 13 {
		t.Fatal(result, ok)
	}
	result, ok = parseMediaProbe([]byte(`{"streams":[{"codec_type":"audio","duration":"3.4"}],"format":{}}`))
	if !ok || result.Width != nil || result.Duration == nil || *result.Duration != 3 {
		t.Fatal(result, ok)
	}
	result, ok = parseMediaProbe([]byte(`{"streams":[{"codec_type":"audio","duration":"3.4"}],"format":{"duration":"N/A"}}`))
	if !ok || result.Duration != nil {
		t.Fatal(result, ok)
	}
	if _, ok := parseMediaProbe([]byte("invalid")); ok {
		t.Fatal("invalid JSON accepted")
	}
	result, ok = parseMediaProbe([]byte(`{"streams":[{"codec_type":"video","width":0,"height":2.7}],"format":{"duration":"-0.4"}}`))
	if !ok || result.Width != nil || result.Height != nil || result.Duration != nil {
		t.Fatal(result, ok)
	}
}

func TestFFProbeHelper(t *testing.T) {
	mode := os.Getenv("NEKO_TEST_PROBE_MODE")
	if mode == "" {
		return
	}
	switch mode {
	case "valid":
		if runtime.GOOS == "windows" {
			index := slices.Index(os.Args, "-protocol_whitelist")
			path := os.Args[len(os.Args)-1]
			if index < 0 || index+1 >= len(os.Args) || os.Args[index+1] != "file" || !filepath.IsAbs(path) {
				os.Exit(1)
			}
			data, err := os.ReadFile(path)
			if err != nil || string(data) != "data" {
				os.Exit(1)
			}
		}
		fmt.Print(`{"format":{"duration":"1.6"},"streams":[]}`)
	case "large":
		fmt.Print(strings.Repeat("x", 70000))
	case "wait":
		time.Sleep(5 * time.Second)
	}
	os.Exit(0)
}

func TestMediaProbeLimitsAndRestoresFile(t *testing.T) {
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.CreateTemp(t.TempDir(), "media-")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err = file.WriteString("data"); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		mode  string
		valid bool
	}{{"valid", true}, {"large", false}, {"wait", false}} {
		t.Setenv("NEKO_TEST_PROBE_MODE", tc.mode)
		ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
		result := probeMedia(ctx, file, "audio/wav", probeOptions{Binary: binary, PrefixArgs: []string{"-test.run=^TestFFProbeHelper$", "--"}})
		cancel()
		if (result.Duration != nil) != tc.valid {
			t.Fatal(tc.mode, result)
		}
		position, err := file.Seek(0, 1)
		if err != nil || position != 0 {
			t.Fatal(tc.mode, position, err)
		}
	}
}
