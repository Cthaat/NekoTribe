package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

var errPublicTermsCatalog = errors.New("invalid public terms catalog")
var errPublicTermsQuery = errors.New("invalid public terms query")
var errPublicTermsReference = errors.New("invalid public terms reference")

type publicTermsReference struct {
	Kind    string `json:"kind"`
	ID      int64  `json:"id"`
	Version string `json:"version"`
}
type publicTermsSource struct {
	publicTermsReference
	Key    string   `json:"key"`
	Locale string   `json:"locale"`
	Href   string   `json:"href"`
	Title  string   `json:"title"`
	Blocks []string `json:"blocks"`
}
type termsDocument struct {
	Key    string   `json:"key"`
	Locale string   `json:"locale"`
	Href   string   `json:"href"`
	Title  string   `json:"title"`
	Blocks []string `json:"blocks"`
}

func termsTextValid(s string) bool {
	return utf8.ValidString(s) && len(s) <= 65536 && strings.TrimFunc(s, jsTrimSpace) != ""
}
func termsVersion(id int64, d termsDocument) string {
	h := sha256.New()
	h.Write([]byte("neko-ai-terms-v1\x00"))
	fields := []string{strconv.FormatInt(id, 10), d.Key, d.Locale, d.Href, d.Title, strconv.Itoa(len(d.Blocks))}
	fields = append(fields, d.Blocks...)
	for _, field := range fields {
		fmt.Fprintf(h, "%d:", len(field))
		h.Write([]byte(field))
	}
	return hex.EncodeToString(h.Sum(nil))
}

// Parse only the approved static catalog. Authentication and deployment consistency remain caller responsibilities.
func parsePublicTermsCatalog(raw []byte) ([]publicTermsSource, error) {
	if _, ok := ai.DecodeScalarJSON(raw, 8); !ok {
		return nil, errPublicTermsCatalog
	}
	var pack struct {
		ID        string          `json:"id"`
		Revision  int             `json:"revision"`
		Source    string          `json:"source"`
		Documents []termsDocument `json:"documents"`
	}
	if json.Unmarshal(raw, &pack) != nil || pack.ID != "AI-PUBLIC-TERMS-CATALOG" || pack.Revision != 1 || pack.Source != "i18n/locales/{locale}.json#auth.terms.sections" || len(pack.Documents) != 8 {
		return nil, errPublicTermsCatalog
	}
	var out []publicTermsSource
	for li, locale := range []string{"zh", "en"} {
		for i, section := range []string{"acceptance", "accounts", "conduct", "termination"} {
			key, href := "terms."+section, "/"+locale+"/auth/terms#"+section
			var match *termsDocument
			for j := range pack.Documents {
				d := &pack.Documents[j]
				if d.Key == key && d.Locale == locale {
					if match != nil {
						return nil, errPublicTermsCatalog
					}
					match = d
				}
			}
			count := 1
			if section == "conduct" {
				count = 5
			}
			if match == nil || match.Href != href || !termsTextValid(match.Title) || len(match.Blocks) != count {
				return nil, errPublicTermsCatalog
			}
			for _, block := range match.Blocks {
				if !termsTextValid(block) {
					return nil, errPublicTermsCatalog
				}
			}
			id := int64(li*4 + i + 1)
			out = append(out, publicTermsSource{publicTermsReference: publicTermsReference{Kind: "terms", ID: id, Version: termsVersion(id, *match)}, Key: key, Locale: locale, Href: href, Title: match.Title, Blocks: append([]string(nil), match.Blocks...)})
		}
	}
	return out, nil
}
func clonePublicTerms(src publicTermsSource) publicTermsSource {
	src.Blocks = append([]string(nil), src.Blocks...)
	return src
}
func discoverPublicTerms(catalog []publicTermsSource, query string, limit int) ([]publicTermsSource, error) {
	if !utf8.ValidString(query) || limit < 1 || limit > 20 {
		return nil, errPublicTermsQuery
	}
	term := strings.TrimFunc(query, jsTrimSpace)
	if term == "" || len(term) > 256 || strings.IndexFunc(term, func(r rune) bool { return r <= 0x1f || r == 0x7f }) >= 0 {
		return nil, errPublicTermsQuery
	}
	out := []publicTermsSource{}
	for _, doc := range catalog {
		match := strings.Contains(doc.Title, term)
		for _, block := range doc.Blocks {
			match = match || strings.Contains(block, term)
		}
		if match {
			out = append(out, clonePublicTerms(doc))
			if len(out) == limit {
				break
			}
		}
	}
	return out, nil
}
func hydratePublicTerms(catalog []publicTermsSource, refs []publicTermsReference) ([]publicTermsSource, error) {
	if len(refs) > 20 {
		return nil, errPublicTermsReference
	}
	seen := map[int64]bool{}
	out := []publicTermsSource{}
	for _, ref := range refs {
		if ref.Kind != "terms" || !validKnowledgeID(ref.ID) || !knowledgeVersion.MatchString(ref.Version) || seen[ref.ID] {
			return nil, errPublicTermsReference
		}
		seen[ref.ID] = true
		for _, row := range catalog {
			if row.ID == ref.ID && row.Version == ref.Version {
				out = append(out, clonePublicTerms(row))
				break
			}
		}
	}
	return out, nil
}
