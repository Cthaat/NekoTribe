package server

import (
	"context"
	"database/sql"
	"strings"
	"unicode/utf8"
)

type knowledgeDiscoveryReader interface {
	search(context.Context, int64, string, string, int) ([]knowledgeSource, error)
}

func discoverKnowledge(ctx context.Context, reader knowledgeDiscoveryReader, viewer int64, query string, limit int) ([]knowledgeSource, error) {
	if viewer <= 0 || viewer > 9007199254740991 || !utf8.ValidString(query) || limit < 1 || limit > 20 {
		return nil, errKnowledgeInvalid
	}
	term := strings.TrimFunc(query, jsTrimSpace)
	if term == "" || len(term) > 256 || strings.IndexFunc(term, func(r rune) bool { return r <= 0x1f || r == 0x7f }) >= 0 {
		return nil, errKnowledgeInvalid
	}
	lists := make([][]knowledgeSource, 0, 2)
	for _, kind := range []string{"post", "comment"} {
		rows, err := reader.search(ctx, viewer, kind, term, limit)
		if err != nil || len(rows) > limit {
			return nil, errSessionStore
		}
		valid := make([]knowledgeSource, 0, len(rows))
		seen := make(map[int64]bool)
		for _, row := range rows {
			if row.Kind != kind || !validKnowledgeID(row.ID) || !validKnowledgeID(row.PostID) || (kind == "post" && row.ID != row.PostID) || seen[row.ID] || !utf8.ValidString(row.Content) {
				return nil, errSessionStore
			}
			seen[row.ID] = true
			if row.Content == "" || len(row.Content) > 65536 {
				continue
			}
			row.Version = knowledgeSourceVersion(kind, row.ID, row.PostID, row.Content)
			valid = append(valid, row)
		}
		lists = append(lists, valid)
	}
	result := make([]knowledgeSource, 0, limit)
	for i := 0; len(result) < limit && (i < len(lists[0]) || i < len(lists[1])); i++ {
		for _, list := range lists {
			if i < len(list) && len(result) < limit {
				result = append(result, list[i])
			}
		}
	}
	return result, nil
}

const knowledgeDiscoverPostsSQL = `SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p WHERE p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(p.content,:term)>0 ORDER BY p.post_id DESC FETCH FIRST :row_limit ROWS ONLY`
const knowledgeDiscoverCommentsSQL = `SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.is_deleted=0 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(c.content,:term)>0 ORDER BY c.comment_id DESC FETCH FIRST :row_limit ROWS ONLY`

func (r oracleKnowledgeReader) search(ctx context.Context, viewer int64, kind, term string, limit int) ([]knowledgeSource, error) {
	query := knowledgeDiscoverPostsSQL
	if kind == "comment" {
		query = knowledgeDiscoverCommentsSQL
	}
	rows, err := r.conn.QueryContext(ctx, query, sql.Named("viewer_id", viewer), sql.Named("term", term), sql.Named("row_limit", limit))
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	result := make([]knowledgeSource, 0, limit)
	for rows.Next() {
		row := knowledgeSource{Kind: kind}
		if len(result) >= limit || rows.Scan(&row.ID, &row.PostID, &row.Content) != nil {
			return nil, errSessionStore
		}
		result = append(result, row)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, errSessionStore
	}
	return result, nil
}

// Callers must authenticate the viewer before passing their identity.
func (s OracleSessions) discoverKnowledgeSources(ctx context.Context, viewer int64, query string, limit int) (result []knowledgeSource, err error) {
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
	return discoverKnowledge(ctx, oracleKnowledgeReader{conn}, viewer, query, limit)
}
