package server

import (
	"encoding/binary"
	"math"
	"os"
)

// pcmWAVDuration reads only RIFF chunk headers and a PCM format prefix. It
// never follows paths in uploaded content or loads the audio payload in memory.
func pcmWAVDuration(file *os.File) *float64 {
	info, err := file.Stat()
	if err != nil || info.Size() < 12 {
		return nil
	}
	var header [12]byte
	if _, err := file.ReadAt(header[:], 0); err != nil || string(header[:4]) != "RIFF" || string(header[8:]) != "WAVE" {
		return nil
	}
	end := int64(binary.LittleEndian.Uint32(header[4:8])) + 8
	if end < 12 || end > info.Size() {
		return nil
	}
	var byteRate uint32
	var blockAlign uint16
	var dataSize int64 = -1
	pos := int64(12)
	for chunks := 0; pos+8 <= end && chunks < 1024; chunks++ {
		var chunk [8]byte
		if _, err := file.ReadAt(chunk[:], pos); err != nil {
			return nil
		}
		size := int64(binary.LittleEndian.Uint32(chunk[4:]))
		start := pos + 8
		if size > end-start || size+(size&1) > end-start {
			return nil
		}
		switch string(chunk[:4]) {
		case "fmt ":
			if byteRate != 0 || size < 16 {
				return nil
			}
			var format [16]byte
			if _, err := file.ReadAt(format[:], start); err != nil {
				return nil
			}
			kind := binary.LittleEndian.Uint16(format[0:2])
			channels := binary.LittleEndian.Uint16(format[2:4])
			rate := binary.LittleEndian.Uint32(format[4:8])
			bytes := binary.LittleEndian.Uint32(format[8:12])
			block := binary.LittleEndian.Uint16(format[12:14])
			bits := binary.LittleEndian.Uint16(format[14:16])
			if (kind != 1 && kind != 3) || channels == 0 || rate == 0 || bits == 0 || bits%8 != 0 || uint64(channels)*uint64(bits/8) != uint64(block) || uint64(rate)*uint64(block) != uint64(bytes) {
				return nil
			}
			byteRate = bytes
			blockAlign = block
		case "data":
			if dataSize >= 0 {
				return nil
			}
			dataSize = size
		}
		pos = start + size + (size & 1)
	}
	if pos != end || byteRate == 0 || dataSize < 0 || dataSize%int64(blockAlign) != 0 {
		return nil
	}
	seconds := math.Floor(float64(dataSize)/float64(byteRate) + 0.5)
	return &seconds
}
