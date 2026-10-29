package server

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"regexp"
	"sort"
	"strings"
)

const maxMediaArchiveDirectory = 4 << 20
const maxMediaArchiveEntries = 10000
const maxMediaArchiveMetadata = 1 << 20

type mediaReaderAt struct {
	ctx    context.Context
	reader io.ReaderAt
}

func (r mediaReaderAt) ReadAt(p []byte, off int64) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.ReadAt(p, off)
}

// detectMediaFile inspects containers from a request-owned seekable file.
// It does not scan contents for malware and is not yet wired to an API route.
func detectMediaFile(ctx context.Context, reader io.ReaderAt, size int64) (*mediaDetectedType, error) {
	if size < 0 || size > 500<<20 || ctx.Err() != nil {
		return nil, errMediaStorage
	}
	r := mediaReaderAt{ctx, reader}
	prefix := make([]byte, min(size, int64(4096)))
	if len(prefix) > 0 {
		n, err := r.ReadAt(prefix, 0)
		if err != nil && !(errors.Is(err, io.EOF) && n == len(prefix)) {
			return nil, errMediaStorage
		}
		if n != len(prefix) {
			return nil, errMediaStorage
		}
	}
	if bytes.HasPrefix(prefix, []byte{'P', 'K', 3, 4}) {
		return detectMediaZip(r, size)
	}
	if len(prefix) == 4096 && bytes.HasPrefix(prefix, []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}) && !pngHasDecisiveChunk(prefix) {
		return detectMediaPNG(r, size)
	}
	return detectMediaContent(io.NewSectionReader(r, 0, size))
}

func detectMediaPNG(reader io.ReaderAt, size int64) (*mediaDetectedType, error) {
	var header [8]byte
	offset := int64(8)
	for chunks := 0; chunks < maxMediaArchiveEntries; chunks++ {
		if offset+8 > size {
			return &mediaDetectedType{Ext: "png", MIME: "image/png"}, nil
		}
		if _, err := reader.ReadAt(header[:], offset); err != nil {
			return nil, errMediaStorage
		}
		length := uint64(binary.BigEndian.Uint32(header[:4]))
		if length > 0x7fffffff {
			return nil, errMediaStorage
		}
		switch string(header[4:]) {
		case "IDAT":
			return &mediaDetectedType{Ext: "png", MIME: "image/png"}, nil
		case "acTL":
			return &mediaDetectedType{Ext: "apng", MIME: "image/apng"}, nil
		}
		next := uint64(offset) + 12 + length
		if next > uint64(size) {
			return nil, errMediaStorage
		}
		offset = int64(next)
	}
	return nil, errMediaStorage
}

type mediaZipEnd struct {
	entries         uint16
	directoryOffset uint32
}

func validateMediaZipEnd(reader io.ReaderAt, size int64) (mediaZipEnd, error) {
	if size < 22 {
		return mediaZipEnd{}, errMediaStorage
	}
	length := min(size, int64(22+65535))
	tail := make([]byte, length)
	if _, err := reader.ReadAt(tail, size-length); err != nil {
		return mediaZipEnd{}, errMediaStorage
	}
	for pos := len(tail) - 22; pos >= 0; pos-- {
		if !bytes.Equal(tail[pos:pos+4], []byte{'P', 'K', 5, 6}) {
			continue
		}
		comment := int(binary.LittleEndian.Uint16(tail[pos+20 : pos+22]))
		if pos+22+comment != len(tail) {
			continue
		}
		disk := binary.LittleEndian.Uint16(tail[pos+4 : pos+6])
		startDisk := binary.LittleEndian.Uint16(tail[pos+6 : pos+8])
		diskEntries := binary.LittleEndian.Uint16(tail[pos+8 : pos+10])
		entries := binary.LittleEndian.Uint16(tail[pos+10 : pos+12])
		dirSize := binary.LittleEndian.Uint32(tail[pos+12 : pos+16])
		dirOffset := binary.LittleEndian.Uint32(tail[pos+16 : pos+20])
		endOffset := size - length + int64(pos)
		if disk != 0 || startDisk != 0 || diskEntries != entries || entries == 0xffff || entries > maxMediaArchiveEntries || dirSize == 0xffffffff || dirOffset == 0xffffffff || dirSize > maxMediaArchiveDirectory || int64(dirOffset)+int64(dirSize) != endOffset {
			return mediaZipEnd{}, errMediaStorage
		}
		return mediaZipEnd{entries: entries, directoryOffset: dirOffset}, nil
	}
	return mediaZipEnd{}, errMediaStorage
}

var mediaAPKName = regexp.MustCompile(`classes[0-9]*\.dex`)

type mediaZipOrderedFile struct {
	file   *zip.File
	offset int64
}

func detectMediaZip(reader io.ReaderAt, size int64) (*mediaDetectedType, error) {
	end, err := validateMediaZipEnd(reader, size)
	if err != nil {
		return nil, err
	}
	archive, err := zip.NewReader(reader, size)
	if err != nil || len(archive.File) != int(end.entries) {
		return nil, errMediaStorage
	}
	files := make([]mediaZipOrderedFile, 0, len(archive.File))
	for _, file := range archive.File {
		offset, err := file.DataOffset()
		if err != nil || offset < 0 || uint64(offset) > uint64(end.directoryOffset) || file.CompressedSize64 > uint64(end.directoryOffset)-uint64(offset) {
			return nil, errMediaStorage
		}
		files = append(files, mediaZipOrderedFile{file, offset})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].offset < files[j].offset })
	if err := validateMediaZipLocalEntries(reader, end.directoryOffset, files); err != nil {
		return nil, errMediaStorage
	}
	for _, item := range files {
		file := item.file
		switch file.Name {
		case "META-INF/mozilla.rsa":
			return &mediaDetectedType{Ext: "xpi", MIME: "application/x-xpinstall"}, nil
		case "META-INF/MANIFEST.MF":
			return &mediaDetectedType{Ext: "jar", MIME: "application/java-archive"}, nil
		case "mimetype", "[Content_Types].xml":
			if file.CompressedSize64 > maxMediaArchiveMetadata || file.UncompressedSize64 > maxMediaArchiveMetadata {
				return nil, errMediaStorage
			}
			stream, err := file.Open()
			if err != nil {
				return nil, errMediaStorage
			}
			data, readErr := io.ReadAll(io.LimitReader(stream, maxMediaArchiveMetadata+1))
			closeErr := stream.Close()
			if readErr != nil || closeErr != nil || len(data) > maxMediaArchiveMetadata {
				return nil, errMediaStorage
			}
			mime := string(data)
			if file.Name == "mimetype" {
				mime = strings.TrimFunc(mime, jsTrimSpace)
			} else if end := strings.Index(mime, `.main+xml"`); end >= 0 {
				mime = mime[:end]
				if start := strings.LastIndex(mime, `"`); start >= 0 {
					mime = mime[start+1:]
				} else {
					mime = ""
				}
			} else if strings.Contains(mime, `ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"`) {
				mime = "application/vnd.ms-package.3dmanufacturing-3dmodel+xml"
			} else {
				mime = ""
			}
			if detected := mediaZipMIME(strings.ToLower(mime)); detected != nil {
				return detected, nil
			}
			return &mediaDetectedType{Ext: "zip", MIME: "application/zip"}, nil
		default:
			if mediaAPKName.MatchString(file.Name) {
				return &mediaDetectedType{Ext: "apk", MIME: "application/vnd.android.package-archive"}, nil
			}
		}
	}
	return &mediaDetectedType{Ext: "zip", MIME: "application/zip"}, nil
}

func validateMediaZipLocalEntries(reader io.ReaderAt, directoryOffset uint32, files []mediaZipOrderedFile) error {
	var position int64
	var header [30]byte
	for _, item := range files {
		if position < 0 || position+30 > int64(directoryOffset) {
			return errMediaStorage
		}
		if _, err := reader.ReadAt(header[:], position); err != nil {
			return errMediaStorage
		}
		if !bytes.Equal(header[:4], []byte{'P', 'K', 3, 4}) {
			return errMediaStorage
		}
		flags := binary.LittleEndian.Uint16(header[6:8])
		method := binary.LittleEndian.Uint16(header[8:10])
		nameLength := int(binary.LittleEndian.Uint16(header[26:28]))
		extraLength := int(binary.LittleEndian.Uint16(header[28:30]))
		if flags != item.file.Flags || flags&1 != 0 || method != item.file.Method || item.file.CompressedSize64 > 0xffffffff || item.file.UncompressedSize64 > 0xffffffff {
			return errMediaStorage
		}
		if position+30+int64(nameLength)+int64(extraLength) != item.offset {
			return errMediaStorage
		}
		name := make([]byte, nameLength)
		if _, err := reader.ReadAt(name, position+30); err != nil {
			return errMediaStorage
		}
		if string(name) != item.file.Name {
			return errMediaStorage
		}
		position = item.offset + int64(item.file.CompressedSize64)
		if flags&8 == 0 {
			if binary.LittleEndian.Uint32(header[14:18]) != item.file.CRC32 || uint64(binary.LittleEndian.Uint32(header[18:22])) != item.file.CompressedSize64 || uint64(binary.LittleEndian.Uint32(header[22:26])) != item.file.UncompressedSize64 {
				return errMediaStorage
			}
		} else {
			if position+12 > int64(directoryOffset) {
				return errMediaStorage
			}
			var descriptor [16]byte
			if _, err := reader.ReadAt(descriptor[:4], position); err != nil {
				return errMediaStorage
			}
			if bytes.Equal(descriptor[:4], []byte{'P', 'K', 7, 8}) {
				position += 4
			}
			if position+12 > int64(directoryOffset) {
				return errMediaStorage
			}
			if _, err := reader.ReadAt(descriptor[:12], position); err != nil {
				return errMediaStorage
			}
			if binary.LittleEndian.Uint32(descriptor[:4]) != item.file.CRC32 || uint64(binary.LittleEndian.Uint32(descriptor[4:8])) != item.file.CompressedSize64 || uint64(binary.LittleEndian.Uint32(descriptor[8:12])) != item.file.UncompressedSize64 {
				return errMediaStorage
			}
			position += 12
		}
	}
	if position != int64(directoryOffset) {
		return errMediaStorage
	}
	return nil
}

func mediaZipMIME(mime string) *mediaDetectedType {
	extensions := map[string]string{
		"application/epub+zip": "epub", "application/vnd.oasis.opendocument.text": "odt", "application/vnd.oasis.opendocument.text-template": "ott", "application/vnd.oasis.opendocument.spreadsheet": "ods", "application/vnd.oasis.opendocument.spreadsheet-template": "ots", "application/vnd.oasis.opendocument.presentation": "odp", "application/vnd.oasis.opendocument.presentation-template": "otp", "application/vnd.oasis.opendocument.graphics": "odg", "application/vnd.oasis.opendocument.graphics-template": "otg", "application/vnd.openxmlformats-officedocument.presentationml.slideshow": "ppsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.template": "xltx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.template": "dotx", "application/vnd.openxmlformats-officedocument.presentationml.template": "potx", "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
	}
	if ext := extensions[mime]; ext != "" {
		return &mediaDetectedType{Ext: ext, MIME: mime}
	}
	for _, item := range []struct{ input, ext, output string }{
		{"application/vnd.ms-excel.sheet.macroenabled", "xlsm", "application/vnd.ms-excel.sheet.macroenabled.12"}, {"application/vnd.ms-excel.template.macroenabled", "xltm", "application/vnd.ms-excel.template.macroenabled.12"}, {"application/vnd.ms-powerpoint.slideshow.macroenabled", "ppsm", "application/vnd.ms-powerpoint.slideshow.macroenabled.12"}, {"application/vnd.ms-word.document.macroenabled", "docm", "application/vnd.ms-word.document.macroenabled.12"}, {"application/vnd.ms-word.template.macroenabledtemplate", "dotm", "application/vnd.ms-word.template.macroenabled.12"}, {"application/vnd.ms-powerpoint.template.macroenabled", "potm", "application/vnd.ms-powerpoint.template.macroenabled.12"}, {"application/vnd.ms-powerpoint.presentation.macroenabled", "pptm", "application/vnd.ms-powerpoint.presentation.macroenabled.12"}, {"application/vnd.ms-visio.drawing", "vsdx", "application/vnd.visio"}, {"application/vnd.ms-package.3dmanufacturing-3dmodel+xml", "3mf", "model/3mf"},
	} {
		if mime == item.input {
			return &mediaDetectedType{Ext: item.ext, MIME: item.output}
		}
	}
	return nil
}
