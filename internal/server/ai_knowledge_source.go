package server

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"unicode/utf8"
)

var errKnowledgeInvalid = errors.New("invalid knowledge source")
var knowledgeVersion = regexp.MustCompile(`^[0-9a-f]{64}$`)

const knowledgeMaxID int64 = 999999999999999

type knowledgeCandidate struct {
	Kind    string `json:"kind"`
	ID      int64  `json:"id"`
	Version string `json:"version"`
}
type knowledgeSource struct {
	Kind    string `json:"kind"`
	ID      int64  `json:"id"`
	PostID  int64  `json:"post_id,omitempty"`
	Content string `json:"content"`
	Version string `json:"version"`
}
type knowledgeReader interface {
	get(context.Context, int64, knowledgeCandidate) (knowledgeSource, bool, error)
}

func knowledgeSourceVersion(kind string, id, postID int64, content string) string {
	h := sha256.New()
	fmt.Fprintf(h, "neko-ai-source-v1\x00%s\x00%d\x00%d\x00", kind, id, postID)
	h.Write([]byte(content))
	return hex.EncodeToString(h.Sum(nil))
}
func validKnowledgeID(id int64) bool { return id > 0 && id <= knowledgeMaxID }
func validateKnowledgeCandidates(viewer int64, candidates []knowledgeCandidate) error {
	if viewer <= 0 || viewer > 9007199254740991 || len(candidates) > 20 {
		return errKnowledgeInvalid
	}
	seen := make(map[string]bool, len(candidates))
	for _, c := range candidates {
		if (c.Kind != "post" && c.Kind != "comment" && c.Kind != "terms") || !validKnowledgeID(c.ID) || (c.Kind == "terms" && c.ID > 8) || !knowledgeVersion.MatchString(c.Version) {
			return errKnowledgeInvalid
		}
		key := fmt.Sprintf("%s:%d", c.Kind, c.ID)
		if seen[key] {
			return errKnowledgeInvalid
		}
		seen[key] = true
	}
	return nil
}
func hydrateKnowledge(ctx context.Context, reader knowledgeReader, viewer int64, candidates []knowledgeCandidate) ([]knowledgeSource, error) {
	if err := validateKnowledgeCandidates(viewer, candidates); err != nil {
		return nil, err
	}
	for _, c := range candidates {
		if c.Kind == "terms" {
			return nil, errKnowledgeInvalid
		}
	}
	result := make([]knowledgeSource, 0, len(candidates))
	for _, c := range candidates {
		row, found, err := reader.get(ctx, viewer, c)
		if err != nil {
			return nil, errSessionStore
		}
		if !found {
			continue
		}
		if row.Kind != c.Kind || row.ID != c.ID || !validKnowledgeID(row.PostID) || (c.Kind == "post" && row.PostID != row.ID) || !utf8.ValidString(row.Content) {
			return nil, errSessionStore
		}
		if row.Content == "" || len(row.Content) > 65536 {
			continue
		}
		version := knowledgeSourceVersion(c.Kind, c.ID, row.PostID, row.Content)
		if version == c.Version {
			row.Version = version
			result = append(result, row)
		}
	}
	return result, nil
}

const knowledgePostSQL = `SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p WHERE p.post_id=:source_id AND p.visibility='public' AND p.is_deleted=0 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND fn_can_view_post(:viewer_id,p.post_id)=1`
const knowledgeCommentSQL = `SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:source_id AND c.is_deleted=0 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1`

type knowledgeQueryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}
type oracleKnowledgeReader struct{ conn knowledgeQueryer }

func (r oracleKnowledgeReader) get(ctx context.Context, viewer int64, c knowledgeCandidate) (knowledgeSource, bool, error) {
	if c.Kind != "post" && c.Kind != "comment" {
		return knowledgeSource{}, false, errKnowledgeInvalid
	}
	query := knowledgePostSQL
	if c.Kind == "comment" {
		query = knowledgeCommentSQL
	}
	rows, err := r.conn.QueryContext(ctx, query, sql.Named("source_id", c.ID), sql.Named("viewer_id", viewer))
	if err != nil {
		return knowledgeSource{}, false, errSessionStore
	}
	defer rows.Close()
	if !rows.Next() {
		if rows.Err() != nil {
			return knowledgeSource{}, false, errSessionStore
		}
		if rows.Close() != nil {
			return knowledgeSource{}, false, errSessionStore
		}
		return knowledgeSource{}, false, nil
	}
	result := knowledgeSource{Kind: c.Kind}
	if rows.Scan(&result.ID, &result.PostID, &result.Content) != nil {
		return knowledgeSource{}, false, errSessionStore
	}
	if rows.Next() || rows.Err() != nil || rows.Close() != nil {
		return knowledgeSource{}, false, errSessionStore
	}
	return result, true, nil
}

// Callers must authenticate the viewer before passing their identity.
func (s OracleSessions) hydrateKnowledgeSources(ctx context.Context, viewer int64, candidates []knowledgeCandidate) (result []knowledgeSource, err error) {
	if err = validateKnowledgeCandidates(viewer, candidates); err != nil {
		return nil, err
	}
	for _, c := range candidates {
		if c.Kind == "terms" {
			return nil, errKnowledgeInvalid
		}
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return nil, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			result = nil
			err = errSessionStore
		}
	}()
	return hydrateKnowledge(ctx, oracleKnowledgeReader{conn}, viewer, candidates)
}
