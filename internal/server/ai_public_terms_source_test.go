package server

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestPublicTermsSourceSharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/requirements/ai-public-terms-catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile("../../contracts/scenarios/ai-public-terms-source-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Versions []struct {
			ID      int64  `json:"id"`
			Version string `json:"version"`
		} `json:"versions"`
		Searches []struct {
			Query string  `json:"query"`
			Limit int     `json:"limit"`
			IDs   []int64 `json:"ids"`
		} `json:"searches"`
	}
	if err = json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	for i, row := range vectors.Versions {
		if catalog[i].ID != row.ID || catalog[i].Version != row.Version {
			t.Fatalf("version %d: %#v", row.ID, catalog[i])
		}
	}
	for _, row := range vectors.Searches {
		result, err := discoverPublicTerms(catalog, row.Query, row.Limit)
		if err != nil {
			t.Fatal(err)
		}
		ids := []int64{}
		for _, v := range result {
			ids = append(ids, v.ID)
		}
		if !reflect.DeepEqual(ids, row.IDs) {
			t.Fatal(row.Query, ids, row.IDs)
		}
	}
}

func TestPublicTermsSourceRejectsTamperingAndCopies(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/requirements/ai-public-terms-catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	result, err := discoverPublicTerms(catalog, "账户", 20)
	if err != nil || len(result) != 1 {
		t.Fatal(result, err)
	}
	ref := publicTermsReference{Kind: "terms", ID: result[0].ID, Version: result[0].Version}
	result[0].Blocks[0] = "mutated"
	restored, err := hydratePublicTerms(catalog, []publicTermsReference{ref})
	if err != nil || len(restored) != 1 || restored[0].Blocks[0] == "mutated" {
		t.Fatal(restored, err)
	}
	ref.Version = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if rows, err := hydratePublicTerms(catalog, []publicTermsReference{ref}); err != nil || len(rows) != 0 {
		t.Fatal(rows, err)
	}
	if _, err := hydratePublicTerms(catalog, []publicTermsReference{ref, ref}); err == nil {
		t.Fatal("duplicate references accepted")
	}
	var updated map[string]any
	if json.Unmarshal(raw, &updated) != nil {
		t.Fatal("decode")
	}
	updated["documents"].([]any)[1].(map[string]any)["blocks"].([]any)[0] = "updated"
	updatedRaw, _ := json.Marshal(updated)
	newCatalog, err := parsePublicTermsCatalog(updatedRaw)
	if err != nil {
		t.Fatal(err)
	}
	oldRef := publicTermsReference{Kind: "terms", ID: catalog[1].ID, Version: catalog[1].Version}
	if rows, err := hydratePublicTerms(newCatalog, []publicTermsReference{oldRef}); err != nil || len(rows) != 0 {
		t.Fatal("changed content was not invalidated", rows, err)
	}
	for _, query := range []string{"", "\x00", strings.Repeat("x", 257)} {
		if _, err := discoverPublicTerms(catalog, query, 10); err == nil {
			t.Fatal("invalid query accepted", query)
		}
	}
	var changed map[string]any
	if json.Unmarshal(raw, &changed) != nil {
		t.Fatal("decode")
	}
	changed["documents"].([]any)[0].(map[string]any)["href"] = "https://invalid"
	broken, _ := json.Marshal(changed)
	if _, err := parsePublicTermsCatalog(broken); err == nil {
		t.Fatal("external href accepted")
	}
}
