package server

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestKnowledgeSearchBodySharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/ai-knowledge-search-body.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID, Body string
			Accepted bool
			Phrase   *string
		}
	}
	if err = json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, c := range fixture.Cases {
		got, err := parseKnowledgeSearchBody([]byte(c.Body))
		if (err == nil) != c.Accepted {
			t.Fatalf("%s: %v", c.ID, err)
		}
		if c.Accepted && ((got == nil) != (c.Phrase == nil) || (got != nil && *got != *c.Phrase)) {
			t.Fatalf("%s: %v", c.ID, got)
		}
	}
	for _, raw := range [][]byte{{0xff}, []byte(strings.Repeat(" ", 4097)), []byte(`{"search_phrase":"` + strings.Repeat("猫", 86) + `"}`)} {
		if _, err := parseKnowledgeSearchBody(raw); err == nil {
			t.Fatal("accepted invalid body")
		}
	}
}
