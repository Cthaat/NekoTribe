package server

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"net/http/httptest"
	"testing"
)

func testAVIFBox(kind string, body []byte) []byte {
	box := make([]byte, 8, 8+len(body))
	binary.BigEndian.PutUint32(box, uint32(8+len(body)))
	copy(box[4:], kind)
	return append(box, body...)
}

func testAVIFIspe(width, height uint32) []byte {
	body := make([]byte, 12)
	binary.BigEndian.PutUint32(body[4:], width)
	binary.BigEndian.PutUint32(body[8:], height)
	return testAVIFBox("ispe", body)
}

func TestAVIFUsesPrimaryAssociation(t *testing.T) {
	pitm := testAVIFBox("pitm", []byte{0, 0, 0, 0, 0, 2})
	properties := append(testAVIFIspe(1, 1), testAVIFIspe(17, 9)...)
	ipco := testAVIFBox("ipco", properties)
	ipma := testAVIFBox("ipma", []byte{0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 1, 1, 0, 2, 1, 2})
	iprp := testAVIFBox("iprp", append(ipco, ipma...))
	meta := testAVIFBox("meta", append(append([]byte{0, 0, 0, 0}, pitm...), iprp...))
	// A media payload can extend beyond the bounded prefix without blocking metadata.
	data := append(meta, []byte{0, 0, 1, 0, 'm', 'd', 'a', 't'}...)
	w, h, ok := avifDimensions(data)
	if !ok || w != 17 || h != 9 {
		t.Fatal(w, h, ok)
	}
	bad := bytes.Clone(meta)
	bad[len(bad)-1] = 3
	if _, _, ok := avifDimensions(bad); ok {
		t.Fatal("accepted missing property")
	}
}

const avifSample = "AAAAHGZ0eXBhdmlmAAAAAG1pZjFhdmlmbWlhZgAAANZtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAAA5waXRtAAAAAAABAAAAImlsb2MAAAAAREAAAQABAAAAAAD6AAEAAAAAAAAAGgAAACNpaW5mAAAAAAABAAAAFWluZmUCAAAAAAEAAGF2MDEAAAAAVmlwcnAAAAA4aXBjbwAAAAxhdjFDgSACAAAAABRpc3BlAAAAAAAAAAcAAAAFAAAAEHBpeGkAAAAAAwgICAAAABZpcG1hAAAAAAAAAAEAAQOBAgMAAAAibWRhdBIACgg4CLRhAQ0GkDIMGAAAAEAF9e7WR/Sb"

func TestAVIFDimensions(t *testing.T) {
	data, err := base64.StdEncoding.DecodeString(avifSample)
	if err != nil {
		t.Fatal(err)
	}
	w, h, ok := avifDimensions(data)
	if !ok || w != 7 || h != 5 {
		t.Fatal(w, h, ok)
	}
	for _, end := range []int{0, 7, 28, 100, 200} {
		if _, _, ok := avifDimensions(data[:end]); ok {
			t.Fatal("accepted truncated", end)
		}
	}
	broken := append([]byte(nil), data...)
	binary.BigEndian.PutUint32(broken[:4], 0xffffffff)
	if _, _, ok := avifDimensions(broken); ok {
		t.Fatal("accepted oversized box")
	}
}

func TestMediaUploadAVIFDimensions(t *testing.T) {
	data, err := base64.StdEncoding.DecodeString(avifSample)
	if err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	store := &mediaUploadFixture{memorySessions: store()}
	body, typ := multipartFixture(t, []partFixture{{"file", "a.avif", string(data)}})
	req := httptest.NewRequest("POST", "/api/v2/media", body)
	req.Header.Set("Content-Type", typ)
	req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: t.TempDir()}}).ServeHTTP(w, req)
	if w.Code != 200 || store.input.MIMEType != "image/avif" || store.input.Width == nil || *store.input.Width != 7 || store.input.Height == nil || *store.input.Height != 5 {
		t.Fatal(w.Code, store.input, w.Body.String())
	}
}
