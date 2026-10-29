package server

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestMediaContainerSharedSamples(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/media-container-samples.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID, Base64 string
			Expected   *mediaDetectedType
		}
	}
	if err = json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	for _, c := range vectors.Cases {
		t.Run(c.ID, func(t *testing.T) {
			raw, err := base64.StdEncoding.DecodeString(c.Base64)
			if err != nil || len(raw) <= 4096 {
				t.Fatal(err)
			}
			actual, err := detectMediaFile(context.Background(), bytes.NewReader(raw), int64(len(raw)))
			if err != nil || !reflect.DeepEqual(actual, c.Expected) {
				t.Fatalf("got %#v err %v want %#v", actual, err, c.Expected)
			}
		})
	}
}

func TestMediaContainerSupportsStreamingZipDescriptor(t *testing.T) {
	var out bytes.Buffer
	w := zip.NewWriter(&out)
	entry, err := w.CreateHeader(&zip.FileHeader{Name: "data.bin", Method: zip.Store})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = entry.Write(bytes.Repeat([]byte{'A'}, 5000)); err != nil {
		t.Fatal(err)
	}
	if err = w.Close(); err != nil {
		t.Fatal(err)
	}
	actual, err := detectMediaFile(context.Background(), bytes.NewReader(out.Bytes()), int64(out.Len()))
	if err != nil || actual == nil || actual.MIME != "application/zip" {
		t.Fatal(actual, err)
	}
}

func TestMediaContainerBoundsMetadataDecompression(t *testing.T) {
	var out bytes.Buffer
	w := zip.NewWriter(&out)
	entry, err := w.Create("mimetype")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = entry.Write(bytes.Repeat([]byte{'x'}, maxMediaArchiveMetadata+1)); err != nil {
		t.Fatal(err)
	}
	if err = w.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = detectMediaFile(context.Background(), bytes.NewReader(out.Bytes()), int64(out.Len())); err == nil {
		t.Fatal("oversized metadata accepted")
	}
}

func TestMediaContainerRejectsMalformedAndCancelled(t *testing.T) {
	data := append([]byte{'P', 'K', 3, 4}, bytes.Repeat([]byte{'x'}, 6000)...)
	if _, err := detectMediaFile(context.Background(), bytes.NewReader(data), int64(len(data))); err == nil {
		t.Fatal("malformed zip accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := detectMediaFile(ctx, bytes.NewReader(data), int64(len(data))); err == nil {
		t.Fatal("cancellation ignored")
	}
}

func TestMediaContainerRejectsContradictoryLocalAndCentralNames(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/media-container-samples.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct{ Cases []struct{ ID, Base64 string } }
	if err = json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(vectors.Cases[0].Base64)
	if err != nil {
		t.Fatal(err)
	}
	central := bytes.Index(raw, []byte{'P', 'K', 1, 2})
	if central < 0 {
		t.Fatal("missing central header")
	}
	copy(raw[central+46:central+46+len("padding.bin")], "mimetypexxx")
	if _, err = detectMediaFile(context.Background(), bytes.NewReader(raw), int64(len(raw))); err == nil {
		t.Fatal("accepted contradictory ZIP names")
	}
}

func TestMediaContainerRejectsOversizedAndUnsupportedDirectories(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/media-container-samples.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct{ Cases []struct{ Base64 string } }
	if err = json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	original, err := base64.StdEncoding.DecodeString(vectors.Cases[0].Base64)
	if err != nil {
		t.Fatal(err)
	}
	for _, change := range []func([]byte, int){
		func(b []byte, i int) { binary.LittleEndian.PutUint32(b[i+12:i+16], maxMediaArchiveDirectory+1) },
		func(b []byte, i int) {
			binary.LittleEndian.PutUint16(b[i+8:i+10], 10001)
			binary.LittleEndian.PutUint16(b[i+10:i+12], 10001)
		},
		func(b []byte, i int) { binary.LittleEndian.PutUint16(b[i+4:i+6], 1) },
		func(b []byte, i int) { binary.LittleEndian.PutUint16(b[i+10:i+12], 0xffff) },
	} {
		altered := bytes.Clone(original)
		end := bytes.LastIndex(altered, []byte{'P', 'K', 5, 6})
		if end < 0 {
			t.Fatal("missing end")
		}
		change(altered, end)
		if _, err = detectMediaFile(context.Background(), bytes.NewReader(altered), int64(len(altered))); err == nil {
			t.Fatal("invalid ZIP directory accepted")
		}
	}
}
