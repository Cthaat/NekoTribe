package server

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestMediaTypeSelectionSharedVectors(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/media-type-selection.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID, Name, Uploaded string
			Detected           *mediaDetectedType
			Expected           mediaSelectedType
		}
	}
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	for _, c := range vectors.Cases {
		t.Run(c.ID, func(t *testing.T) {
			if actual := selectMediaFileType(c.Name, c.Uploaded, c.Detected); !reflect.DeepEqual(actual, c.Expected) {
				t.Fatalf("got %#v expected %#v", actual, c.Expected)
			}
		})
	}
}
