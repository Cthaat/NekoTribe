package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

var errKnowledgeIndexTransient = errors.New("knowledge index temporarily unavailable")

var knowledgeIndexHTTP = &http.Client{
	Timeout:       11 * time.Second,
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
}

// The index supplies references only. The knowledge turn hydrates every reference using the caller's permissions.
func discoverIndexedKnowledge(ctx context.Context, viewer int64, address, query string, limit int) ([]knowledgeSource, error) {
	if ctx.Err() != nil {
		return nil, errKnowledgeProvider
	}
	term := strings.TrimFunc(query, jsTrimSpace)
	if limit < 1 || limit > 20 || term == "" || !utf8.ValidString(term) || len(term) > 256 || strings.IndexFunc(term, func(r rune) bool { return r <= 0x1f || r == 0x7f }) >= 0 {
		return nil, errKnowledgeInvalid
	}
	token := os.Getenv("AI_INDEX_SERVICE_TOKEN")
	if len(address) > 2048 || !ai.ValidHTTPBaseURL(address) || len(token) < 32 || len(token) > 512 ||
		strings.IndexFunc(token, func(r rune) bool { return r <= ' ' || r > '~' }) >= 0 {
		return nil, errKnowledgeProvider
	}
	payload, err := json.Marshal(struct {
		Query string `json:"query"`
		Limit int    `json:"limit"`
	}{term, limit})
	if err != nil {
		return nil, errKnowledgeProvider
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(address, "/")+"/internal/v1/knowledge/search", bytes.NewReader(payload))
	if err != nil {
		return nil, errKnowledgeProvider
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Neko-Knowledge-Chunks", "1")
	request.Header.Set("X-Neko-Knowledge-Group-Sources", "1")
	response, err := knowledgeIndexHTTP.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, errKnowledgeProvider
		}
		return nil, errKnowledgeIndexTransient
	}
	defer response.Body.Close()
	if ctx.Err() != nil {
		return nil, errKnowledgeProvider
	}
	if response.StatusCode != http.StatusOK {
		switch response.StatusCode {
		case http.StatusTooManyRequests, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return nil, errKnowledgeIndexTransient
		}
		return nil, errKnowledgeProvider
	}
	const maxBody = 8192
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBody+1))
	if err != nil || ctx.Err() != nil || len(body) > maxBody || !utf8.Valid(body) {
		return nil, errKnowledgeProvider
	}
	// Struct decoding accepts case-insensitive aliases. Check wire keys before decoding values.
	var result map[string]json.RawMessage
	var version int
	var candidates []json.RawMessage
	if json.Unmarshal(body, &result) != nil || len(result) != 2 ||
		json.Unmarshal(result["version"], &version) != nil || version != 1 ||
		json.Unmarshal(result["candidates"], &candidates) != nil || candidates == nil || len(candidates) > limit {
		return nil, errKnowledgeProvider
	}
	sources := make([]knowledgeSource, 0, len(candidates))
	for _, raw := range candidates {
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil || fields["kind"] == nil || fields["id"] == nil || fields["version"] == nil {
			return nil, errKnowledgeProvider
		}
		chunk := fields["chunk"]
		if (chunk == nil && len(fields) != 3) || (chunk != nil && len(fields) != 4) {
			return nil, errKnowledgeProvider
		}
		var hit knowledgeCandidate
		if json.Unmarshal(raw, &hit) != nil {
			return nil, errKnowledgeProvider
		}
		source := knowledgeSource{Kind: hit.Kind, ID: hit.ID, Version: hit.Version, indexed: true}
		if chunk != nil {
			if json.Unmarshal(chunk, &source.Chunk) != nil || source.Chunk == nil || *source.Chunk < 0 || *source.Chunk > 102 {
				return nil, errKnowledgeProvider
			}
		}
		sources = append(sources, source)
	}
	if validateKnowledgeCandidates(viewer, knowledgeCandidates(sources)) != nil {
		return nil, errKnowledgeProvider
	}
	return sources, nil
}
