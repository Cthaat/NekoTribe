package server

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestPostMarkdownRejectsBlankAndReferenceCreation(t *testing.T) {
	for _, body := range []map[string]interface{}{
		{"content": "excerpt", "markdown": "  \t\n"},
		{"content": "excerpt", "markdown": "# heading", "quoted_post_id": float64(8)},
		{"content": "excerpt", "markdown": nil},
	} {
		if _, validation := readPostCreateInput(body, nil); validation == "" {
			t.Errorf("accepted markdown creation %+v", body)
		}
	}
}

func TestPostMarkdownParsersPreserveRawBody(t *testing.T) {
	exact := "  # Title\n\n" + strings.Repeat("猫", (postMarkdown.MaxBytes-12)/3)
	exact += strings.Repeat("x", postMarkdown.MaxBytes-len(exact))
	for _, tc := range []struct {
		name  string
		value any
		valid bool
	}{
		{"maximum bytes", exact, true},
		{"overflow", exact + "x", false},
		{"empty", "", false},
		{"nonstring", false, false},
		{"verbatim", " \n~~~go\nfmt.Println(1)\n~~~\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw, err := json.Marshal(map[string]any{"content": "excerpt", "markdown": tc.value})
			if err != nil {
				t.Fatal(err)
			}
			var body map[string]any
			if err := json.Unmarshal(raw, &body); err != nil {
				t.Fatal(err)
			}
			regular, regularErr := readPostCreateInput(body, nil)
			group := groupPostMutation{action: "create"}
			groupErr := parseGroupPostMutation(raw, &group)
			upd, updateErr := readPostUpdateInput(body)
			if (regularErr == "") != tc.valid || (groupErr == "") != tc.valid || (updateErr == "") != tc.valid {
				t.Fatalf("create %q, group %q, update %q", regularErr, groupErr, updateErr)
			}
			if tc.valid && (*regular.Markdown != tc.value || *group.markdown != tc.value || *upd.markdown.body != tc.value) {
				t.Fatal("Markdown body was altered")
			}
		})
	}
	clear, validation := readPostUpdateInput(map[string]any{"markdown": nil})
	if validation != "" || clear.markdown == nil || clear.markdown.body != nil {
		t.Fatal("explicit null did not clear")
	}
	unchanged, _ := readPostUpdateInput(map[string]any{"content": "new excerpt"})
	if unchanged.markdown != nil {
		t.Fatal("omitted Markdown did not retain")
	}
}

func TestPostMarkdownDraftRoundTripKeepsExpandedJSON(t *testing.T) {
	body := strings.Repeat("\n", postMarkdown.MaxBytes-2) + "#!"
	for _, group := range []any{nil, int64(7)} {
		payload, err := json.Marshal(map[string]any{"group_id": group, "content": "excerpt", "markdown": body})
		if err != nil {
			t.Fatal(err)
		}
		if len(payload) <= 16384 {
			t.Fatalf("fixture did not exceed the earlier payload limit: %d", len(payload))
		}
		draft, err := parsePostDraft(payload)
		if err != nil {
			t.Fatal(err)
		}
		draftBody := draft.regular.Markdown
		if group != nil {
			draftBody = draft.group.markdown
		}
		if draftBody == nil || *draftBody != body || !bytes.Contains(draft.json, []byte(`"markdown":`)) {
			t.Fatal("saved draft omitted or altered Markdown")
		}
	}
}
