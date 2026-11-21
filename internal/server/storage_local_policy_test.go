package server

import (
	"encoding/json"
	"net/http"
	"os"
	"reflect"
	"testing"
)

func TestSharedStorageLocalPolicy(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/storage-local-policy.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		PublicContentTypes map[string]string
		Cases              []struct {
			ID, Kind, Value string
			Size            uint64
			Expected        struct {
				Status int
				Key    string
				Range  *localByteRange
			}
		}
	}
	if err = json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("no shared cases")
	}
	if len(fixture.PublicContentTypes) == 0 {
		t.Fatal("no shared content types")
	}
	for key, want := range fixture.PublicContentTypes {
		headers := make(http.Header)
		setStorageReadHeaders(headers, key, false)
		if got := headers.Get("Content-Type"); got != want {
			t.Errorf("%s: got %q, want %q", key, got, want)
		}
	}
	for _, vector := range fixture.Cases {
		t.Run(vector.ID, func(t *testing.T) {
			if vector.Kind == "key" {
				key, err := normalizeLocalFileKey(vector.Value)
				if vector.Expected.Status == 400 {
					if err == nil {
						t.Fatal("unsafe key accepted")
					}
				} else if err != nil || key != vector.Expected.Key {
					t.Fatal(key, err)
				}
			} else {
				actual, err := parseLocalByteRange(vector.Value, vector.Size)
				if vector.Expected.Status == 416 {
					if err == nil {
						t.Fatal("invalid range accepted")
					}
				} else if err != nil || !reflect.DeepEqual(actual, vector.Expected.Range) {
					t.Fatal(actual, err, vector.Expected.Range)
				}
			}
		})
	}
}
