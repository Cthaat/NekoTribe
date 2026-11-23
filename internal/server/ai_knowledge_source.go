package server

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
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
	GroupID int64  `json:"group_id,omitempty"`
	Content string `json:"content"`
	Version string `json:"version"`
	Chunk   *int   `json:"-"`
	indexed bool
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
func isGroupKnowledgeKind(kind string) bool {
	return kind == "group_post" || kind == "group_comment"
}

func validKnowledgeLocation(kind string, id, postID, groupID int64) bool {
	if kind == "terms" {
		return postID == 0 && groupID == 0
	}
	if !validKnowledgeID(postID) || ((kind == "post" || kind == "group_post") && id != postID) {
		return false
	}
	if isGroupKnowledgeKind(kind) {
		return groupID > 0 && groupID <= maxKnowledgeGroupID
	}
	return groupID == 0
}

var groupKnowledgeQueries = sync.OnceValue(func() map[string]string {
	var queries map[string]string
	if json.Unmarshal([]byte(contracts.AIGroupKnowledgeSource), &queries) != nil {
		return nil
	}
	return queries
})

func validateKnowledgeCandidates(viewer int64, candidates []knowledgeCandidate) error {
	if viewer <= 0 || viewer > 9007199254740991 || len(candidates) > 20 {
		return errKnowledgeInvalid
	}
	seen := make(map[string]bool, len(candidates))
	for _, c := range candidates {
		if (c.Kind != "post" && c.Kind != "comment" && c.Kind != "terms" && !isGroupKnowledgeKind(c.Kind)) || !validKnowledgeID(c.ID) || (c.Kind == "terms" && c.ID > 8) || !knowledgeVersion.MatchString(c.Version) {
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
	result := make([]knowledgeSource, 0, len(candidates))
	for _, c := range candidates {
		row, found, err := reader.get(ctx, viewer, c)
		if err != nil {
			return nil, errSessionStore
		}
		if !found {
			continue
		}
		if row.Kind != c.Kind || row.ID != c.ID || !validKnowledgeLocation(row.Kind, row.ID, row.PostID, row.GroupID) || !utf8.ValidString(row.Content) {
			return nil, errSessionStore
		}
		if row.Content == "" || len(row.Content) > 65536 {
			continue
		}
		version := row.Version
		if c.Kind != "terms" {
			version = knowledgeSourceVersion(c.Kind, c.ID, row.PostID, row.Content)
		}
		if version == c.Version {
			row.Version = version
			result = append(result, row)
		}
	}
	return result, nil
}

const knowledgePostSQL = `SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 WHERE p.post_id=:source_id AND p.post_id BETWEEN 1 AND :max_id AND p.visibility='public' AND p.is_deleted=0 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND fn_can_view_post(:viewer_id,p.post_id)=1`
const knowledgeCommentSQL = `SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 JOIN n_users comment_author ON comment_author.user_id=c.user_id AND comment_author.is_active=1 WHERE c.comment_id=:source_id AND p.post_id BETWEEN 1 AND :max_id AND c.is_deleted=0 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_user_blocks b WHERE (b.user_id=:viewer_id AND b.target_user_id=c.user_id) OR (b.target_user_id=:viewer_id AND b.user_id=c.user_id))`

type knowledgeQueryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}
type oracleKnowledgeReader struct{ conn knowledgeQueryer }

// Only use on an active transaction whose commit or rollback releases the lock.
type lockedKnowledgeReader struct{ conn knowledgeQueryer }

func (r lockedKnowledgeReader) get(ctx context.Context, viewer int64, c knowledgeCandidate) (knowledgeSource, bool, error) {
	return (oracleKnowledgeReader{r.conn}).getMode(ctx, viewer, c, true)
}

func (r oracleKnowledgeReader) get(ctx context.Context, viewer int64, c knowledgeCandidate) (knowledgeSource, bool, error) {
	return r.getMode(ctx, viewer, c, false)
}
func (r oracleKnowledgeReader) getMode(ctx context.Context, viewer int64, c knowledgeCandidate, lock bool) (knowledgeSource, bool, error) {
	if c.Kind == "terms" {
		raw := contracts.PublicTermsCatalog()
		if _, err := readPublicTermsAuthorityMode(ctx, r.conn, viewer, raw, lock); err != nil {
			return knowledgeSource{}, false, errSessionStore
		}
		catalog, err := parsePublicTermsCatalog(raw)
		if err != nil {
			return knowledgeSource{}, false, errSessionStore
		}
		rows, err := hydratePublicTerms(catalog, []publicTermsReference{{Kind: "terms", ID: c.ID, Version: c.Version}})
		if err != nil {
			return knowledgeSource{}, false, errSessionStore
		}
		if len(rows) == 0 {
			return knowledgeSource{}, false, nil
		}
		content := strings.Join(append([]string{rows[0].Title}, rows[0].Blocks...), "\n")
		return knowledgeSource{Kind: "terms", ID: rows[0].ID, Version: rows[0].Version, Content: content}, true, nil
	}
	var query string
	switch c.Kind {
	case "post":
		query = knowledgePostSQL
	case "comment":
		query = knowledgeCommentSQL
	case "group_post", "group_comment":
		query = groupKnowledgeQueries()[c.Kind]
		if query == "" {
			return knowledgeSource{}, false, errSessionStore
		}
	default:
		return knowledgeSource{}, false, errKnowledgeInvalid
	}
	return queryKnowledgeSource(ctx, r.conn, query, c.Kind, sql.Named("source_id", c.ID), sql.Named("viewer_id", viewer), sql.Named("max_id", knowledgeMaxID))
}

func queryKnowledgeSource(ctx context.Context, conn knowledgeQueryer, query, kind string, args ...any) (knowledgeSource, bool, error) {
	rows, err := conn.QueryContext(ctx, query, args...)
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
	result := knowledgeSource{Kind: kind}
	var scanErr error
	if isGroupKnowledgeKind(kind) {
		scanErr = rows.Scan(&result.ID, &result.PostID, &result.Content, &result.GroupID)
	} else {
		scanErr = rows.Scan(&result.ID, &result.PostID, &result.Content)
	}
	if scanErr != nil {
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
