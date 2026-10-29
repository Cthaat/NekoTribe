package server

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
)

type mediaBrokenReader struct{}

func (mediaBrokenReader) Read([]byte) (int, error) { return 0, errors.New("private reader failure") }
func TestMediaContentSharedSignatures(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/media-content-signatures.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID, Hex  string
			Expected *mediaDetectedType
		}
	}
	if err = json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	for _, c := range vectors.Cases {
		t.Run(c.ID, func(t *testing.T) {
			raw, err := hex.DecodeString(c.Hex)
			if err != nil {
				t.Fatal(err)
			}
			actual, err := detectMediaContent(bytes.NewReader(raw))
			if err != nil || !reflect.DeepEqual(actual, c.Expected) {
				t.Fatalf("got %#v err=%v want %#v", actual, err, c.Expected)
			}
		})
	}
}
func TestMediaContentIsBoundedAndReportsReadFailure(t *testing.T) {
	reader := &countedMediaReader{source: bytes.NewReader(bytes.Repeat([]byte{'x'}, 1<<20))}
	if _, err := detectMediaContent(reader); err != nil {
		t.Fatal(err)
	}
	if reader.count > 4096 {
		t.Fatal("unbounded read", reader.count)
	}
	if _, err := detectMediaContent(mediaBrokenReader{}); err == nil {
		t.Fatal("reader error ignored")
	}
}

func TestMediaContentRefusesTruncatedContainerEvidence(t *testing.T) {
	png := make([]byte, 4097)
	copy(png, []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a})
	binary.BigEndian.PutUint32(png[8:12], 4080)
	copy(png[12:16], "tEXt")
	if _, err := detectMediaContent(bytes.NewReader(png)); err == nil {
		t.Fatal("ambiguous PNG accepted")
	}
	zip := make([]byte, 4097)
	copy(zip, []byte{'P', 'K', 3, 4})
	if _, err := detectMediaContent(bytes.NewReader(zip)); err == nil {
		t.Fatal("ambiguous ZIP accepted")
	}
	copy(png[12:16], "IDAT")
	result, err := detectMediaContent(bytes.NewReader(png))
	if err != nil || result == nil || result.MIME != "image/png" {
		t.Fatal("decisive PNG rejected", result, err)
	}
}

func TestMediaContentReadsRequestOwnedFileBeforeSelection(t *testing.T) {
	root := t.TempDir()
	png, err := hex.DecodeString("89504e470d0a1a0a0000000d4948445200000001000000010806000000")
	if err != nil {
		t.Fatal(err)
	}
	body, contentType := multipartFixture(t, []partFixture{{"file", "disguised.txt", string(png)}})
	req := httptest.NewRequest("POST", "/api/v2/media", body)
	req.Header.Set("Content-Type", contentType)
	media, err := parseMediaMultipart(req, LocalStorageConfig{Root: root}, mediaMultipartLimits{fileBytes: 100, totalBytes: 100, fieldBytes: 100, fields: 2, files: 2})
	if err != nil {
		t.Fatal(err)
	}
	defer media.Close()
	file, err := media.OpenSelected()
	if err != nil {
		t.Fatal(err)
	}
	detected, err := detectMediaContent(file)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	selected := selectMediaFileType(media.Selected.Name, media.Selected.MIME, detected)
	if selected.MIMEType != "image/png" || selected.Extension != ".png" || !selected.Supported {
		t.Fatal(selected)
	}
}

type countedMediaReader struct {
	source io.Reader
	count  int
}

func (r *countedMediaReader) Read(p []byte) (int, error) {
	n, err := r.source.Read(p)
	r.count += n
	return n, err
}
