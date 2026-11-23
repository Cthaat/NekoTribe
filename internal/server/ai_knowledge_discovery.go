package server

import (
	"context"
	"database/sql"
	"os"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type knowledgeDiscoveryReader interface {
	search(context.Context, int64, string, string, int) ([]knowledgeSource, error)
}

func discoverKnowledge(ctx context.Context, reader knowledgeDiscoveryReader, viewer int64, query string, limit int) ([]knowledgeSource, error) {
	return discoverKnowledgeByKinds(ctx, reader, viewer, query, limit, []string{"post", "comment", "terms", "group_post", "group_comment"})
}

func discoverKnowledgeByKinds(ctx context.Context, reader knowledgeDiscoveryReader, viewer int64, query string, limit int, kinds []string) ([]knowledgeSource, error) {
	if viewer <= 0 || viewer > 9007199254740991 || !utf8.ValidString(query) || limit < 1 || limit > 20 {
		return nil, errKnowledgeInvalid
	}
	term := strings.TrimFunc(query, jsTrimSpace)
	if term == "" || len(term) > 256 || strings.IndexFunc(term, func(r rune) bool { return r <= 0x1f || r == 0x7f }) >= 0 {
		return nil, errKnowledgeInvalid
	}
	lists := make([][]knowledgeSource, 0, len(kinds))
	for _, kind := range kinds {
		rows, err := reader.search(ctx, viewer, kind, term, limit)
		if err != nil || len(rows) > limit {
			return nil, errSessionStore
		}
		valid := make([]knowledgeSource, 0, len(rows))
		seen := make(map[int64]bool)
		for _, row := range rows {
			if row.Kind != kind || !validKnowledgeID(row.ID) || !validKnowledgeLocation(kind, row.ID, row.PostID, row.GroupID) ||
				(kind == "terms" && (row.ID > 8 || !knowledgeVersion.MatchString(row.Version))) ||
				seen[row.ID] || !utf8.ValidString(row.Content) {
				return nil, errSessionStore
			}
			seen[row.ID] = true
			if row.Content == "" || len(row.Content) > 65536 {
				continue
			}
			if kind != "terms" {
				row.Version = knowledgeSourceVersion(kind, row.ID, row.PostID, row.Content)
			}
			valid = append(valid, row)
		}
		lists = append(lists, valid)
	}
	result := make([]knowledgeSource, 0, limit)
	for i := 0; i < limit && len(result) < limit; i++ {
		for _, list := range lists {
			if i < len(list) && len(result) < limit {
				result = append(result, list[i])
			}
		}
	}
	return result, nil
}

const knowledgeDiscoverPostsSQL = `SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 WHERE p.post_id BETWEEN 1 AND :max_id AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(p.content,:term)>0 ORDER BY p.post_id DESC FETCH FIRST :row_limit ROWS ONLY`
const knowledgeDiscoverCommentsSQL = `SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1 JOIN n_users comment_author ON comment_author.user_id=c.user_id AND comment_author.is_active=1 WHERE c.comment_id BETWEEN 1 AND :max_id AND p.post_id BETWEEN 1 AND :max_id AND c.is_deleted=0 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_user_blocks b WHERE (b.user_id=:viewer_id AND b.target_user_id=c.user_id) OR (b.target_user_id=:viewer_id AND b.user_id=c.user_id)) AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(c.content,:term)>0 ORDER BY c.comment_id DESC FETCH FIRST :row_limit ROWS ONLY`

func (r oracleKnowledgeReader) search(ctx context.Context, viewer int64, kind, term string, limit int) ([]knowledgeSource, error) {
	if kind == "terms" {
		raw := contracts.PublicTermsCatalog()
		catalog, err := parsePublicTermsCatalog(raw)
		if err != nil {
			return nil, errSessionStore
		}
		matches, err := discoverPublicTerms(catalog, term, limit)
		if err != nil {
			return nil, errSessionStore
		}
		if len(matches) > 0 {
			if _, err = readPublicTermsAuthority(ctx, r.conn, viewer, raw); err != nil {
				return nil, errSessionStore
			}
		}
		result := make([]knowledgeSource, 0, len(matches))
		for _, row := range matches {
			result = append(result, knowledgeSource{Kind: "terms", ID: row.ID, Version: row.Version, Content: strings.Join(append([]string{row.Title}, row.Blocks...), "\n")})
		}
		return result, nil
	}
	var query string
	switch kind {
	case "post":
		query = knowledgeDiscoverPostsSQL
	case "comment":
		query = knowledgeDiscoverCommentsSQL
	case "group_post", "group_comment":
		query = groupKnowledgeQueries()["search_"+kind]
		if query == "" {
			return nil, errSessionStore
		}
	default:
		return nil, errKnowledgeInvalid
	}
	return queryKnowledgeSearch(ctx, r.conn, query, kind, limit, sql.Named("viewer_id", viewer), sql.Named("term", term), sql.Named("row_limit", limit), sql.Named("max_id", knowledgeMaxID))
}

func queryKnowledgeSearch(ctx context.Context, conn knowledgeQueryer, query, kind string, limit int, args ...any) ([]knowledgeSource, error) {
	rows, err := conn.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	result := make([]knowledgeSource, 0, limit)
	for rows.Next() {
		row := knowledgeSource{Kind: kind}
		if len(result) >= limit {
			return nil, errSessionStore
		}
		var scanErr error
		if isGroupKnowledgeKind(kind) {
			scanErr = rows.Scan(&row.ID, &row.PostID, &row.Content, &row.GroupID)
		} else {
			scanErr = rows.Scan(&row.ID, &row.PostID, &row.Content)
		}
		if scanErr != nil {
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
func (s OracleSessions) discoverKnowledgeSources(ctx context.Context, viewer int64, query string, limit int) ([]knowledgeSource, error) {
	if address := os.Getenv("AI_KNOWLEDGE_INDEX_URL"); address != "" {
		indexed, indexErr := discoverIndexedKnowledge(ctx, viewer, address, query, limit)
		if indexErr != errKnowledgeIndexTransient {
			return indexed, indexErr
		}
		if os.Getenv("AI_KNOWLEDGE_INDEX_FALLBACK") != "lexical" || ctx.Err() != nil {
			return nil, errKnowledgeProvider
		}
	}
	return s.discoverLexicalKnowledgeSources(ctx, viewer, query, limit)
}

func (s OracleSessions) discoverLexicalKnowledgeSources(ctx context.Context, viewer int64, query string, limit int) (result []knowledgeSource, err error) {
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
