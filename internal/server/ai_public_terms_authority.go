package server

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
)

var errTermsAuthorityUnavailable = errors.New("TERMS_AUTHORITY_UNAVAILABLE")

type termsAuthority struct {
	Digest     string
	Generation int64
}

// The validated parser supplies canonical ID order independently of JSON order.
func publicTermsCatalogDigest(raw []byte) (string, error) {
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	h.Write([]byte("neko-ai-terms-catalog-v1\x00"))
	for _, row := range catalog {
		for _, field := range []string{strconv.FormatInt(row.ID, 10), row.Version} {
			fmt.Fprintf(h, "%d:", len(field))
			h.Write([]byte(field))
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// The caller must authenticate the viewer before invoking this function. It performs
// a fresh read on every invocation and never substitutes a cached authority.
func readPublicTermsAuthority(ctx context.Context, conn knowledgeQueryer, viewer int64, raw []byte) (termsAuthority, error) {
	return readPublicTermsAuthorityMode(ctx, conn, viewer, raw, false)
}
func readPublicTermsAuthorityMode(ctx context.Context, conn knowledgeQueryer, viewer int64, raw []byte, lock bool) (termsAuthority, error) {
	if viewer <= 0 || viewer > 9007199254740991 {
		return termsAuthority{}, errKnowledgeInvalid
	}
	digest, err := publicTermsCatalogDigest(raw)
	if err != nil {
		return termsAuthority{}, errTermsAuthorityUnavailable
	}
	query := `SELECT catalog_digest,generation,enabled FROM n_ai_terms_active WHERE singleton_id=:singleton_id`
	if lock {
		query += ` FOR UPDATE WAIT 5`
	}
	rows, err := conn.QueryContext(ctx, query, sql.Named("singleton_id", 1))
	if err != nil {
		return termsAuthority{}, errTermsAuthorityUnavailable
	}
	defer rows.Close()
	if !rows.Next() {
		return termsAuthority{}, errTermsAuthorityUnavailable
	}
	var result termsAuthority
	var enabled int64
	if rows.Scan(&result.Digest, &result.Generation, &enabled) != nil || rows.Next() || rows.Err() != nil || rows.Close() != nil || result.Digest != digest || enabled != 1 || !validKnowledgeID(result.Generation) {
		return termsAuthority{}, errTermsAuthorityUnavailable
	}
	return result, nil
}
