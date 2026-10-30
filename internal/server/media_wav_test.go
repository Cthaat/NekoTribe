package server

import (
	"encoding/binary"
	"os"
	"testing"
)

func TestPCMWAVDuration(t *testing.T) {
	for _, tc := range []struct {
		name   string
		modify func([]byte) []byte
		valid  bool
	}{
		{"pcm", func(b []byte) []byte { return b }, true},
		{"bad signature", func(b []byte) []byte { b[0] = 'x'; return b }, false},
		{"truncated payload", func(b []byte) []byte { return b[:len(b)-1] }, false},
		{"bad byte rate", func(b []byte) []byte { binary.LittleEndian.PutUint32(b[28:], 1); return b }, false},
		{"compressed", func(b []byte) []byte { binary.LittleEndian.PutUint16(b[20:], 6); return b }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file, err := os.CreateTemp(t.TempDir(), "audio-")
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			if _, err := file.Write(tc.modify(oneSecondWAV())); err != nil {
				t.Fatal(err)
			}
			result := pcmWAVDuration(file)
			if (result != nil) != tc.valid || (result != nil && *result != 1) {
				t.Fatal(result)
			}
		})
	}
}
