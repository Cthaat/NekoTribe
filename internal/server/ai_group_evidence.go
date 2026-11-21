package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

const maxGroupEvidenceInteger = 9007199254740991

var groupEvidenceTimestamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$`)

var groupEvidenceSQL = func() string {
	var spec struct{ Query string }
	if json.Unmarshal(contracts.AIGroupEvidence, &spec) != nil || spec.Query == "" {
		panic("invalid group evidence contract")
	}
	// go-oracledb classifies by the first SQL keyword and rejects standalone WITH.
	return "SELECT * FROM (" + spec.Query + ") WHERE ROWNUM <= 8"
}()

type groupEvidenceQuery struct {
	LookbackDays int
	SearchTerm   *string
	MatchExcerpt bool
	WindowEnd    *string
}

type groupEvidenceExample struct {
	Kind     string `json:"kind"`
	SourceID int64  `json:"source_id"`
	PostID   int64  `json:"post_id"`
	Excerpt  string `json:"excerpt"`
}

type groupEvidence struct {
	WindowStart   string                 `json:"window_start"`
	WindowEnd     string                 `json:"window_end"`
	PostsCount    int64                  `json:"posts_count"`
	CommentsCount int64                  `json:"comments_count"`
	Examples      []groupEvidenceExample `json:"examples"`
}

// actor is the authenticated user and groupID comes from the conversation.
func readGroupEvidence(ctx context.Context, db interface {
	QueryContext(context.Context, string, ...interface{}) (*sql.Rows, error)
}, actor, groupID int64, query groupEvidenceQuery) (groupEvidence, error) {
	var evidence groupEvidence
	if actor < 1 || actor > maxGroupEvidenceInteger || groupID < 1 || groupID > maxGroupEvidenceInteger ||
		(query.LookbackDays != 7 && query.LookbackDays != 30) {
		return evidence, errConversationInvalid
	}
	if query.SearchTerm != nil {
		term := *query.SearchTerm
		if term == "" || len(term) > 256 || !utf8.ValidString(term) ||
			strings.IndexFunc(term, func(ch rune) bool { return ch < 32 || ch == 127 }) >= 0 {
			return evidence, errConversationInvalid
		}
	}
	if query.WindowEnd != nil && !groupEvidenceTimestamp.MatchString(*query.WindowEnd) {
		return evidence, errConversationInvalid
	}
	matchExcerpt := 0
	if query.MatchExcerpt {
		matchExcerpt = 1
	}
	rows, err := db.QueryContext(ctx, groupEvidenceSQL,
		sql.Named("actor_id", actor), sql.Named("group_id", groupID), sql.Named("lookback_days", query.LookbackDays),
		sql.Named("search_term", query.SearchTerm), sql.Named("match_excerpt", matchExcerpt), sql.Named("window_end", query.WindowEnd))
	if err != nil {
		return evidence, errSessionStore
	}
	defer rows.Close()
	evidence.Examples = make([]groupEvidenceExample, 0, 8)
	rowCount := 0
	emptyExamples := false
	for rows.Next() {
		rowCount++
		var start, end string
		var posts, comments int64
		var kind, excerpt sql.NullString
		var sourceID, postID sql.NullInt64
		if rows.Scan(&start, &end, &posts, &comments, &kind, &sourceID, &postID, &excerpt) != nil || rowCount > 8 {
			return groupEvidence{}, errSessionStore
		}
		if rowCount == 1 {
			if !groupEvidenceTimestamp.MatchString(start) || !groupEvidenceTimestamp.MatchString(end) ||
				start >= end || (query.WindowEnd != nil && end != *query.WindowEnd) ||
				posts < 0 || posts > maxGroupEvidenceInteger || comments < 0 || comments > maxGroupEvidenceInteger {
				return groupEvidence{}, errSessionStore
			}
			evidence.WindowStart, evidence.WindowEnd = start, end
			evidence.PostsCount, evidence.CommentsCount = posts, comments
		} else if emptyExamples || start != evidence.WindowStart || end != evidence.WindowEnd ||
			posts != evidence.PostsCount || comments != evidence.CommentsCount {
			return groupEvidence{}, errSessionStore
		}
		if !kind.Valid && !sourceID.Valid && !postID.Valid && !excerpt.Valid && rowCount == 1 {
			emptyExamples = true
			continue
		}
		if !kind.Valid || (kind.String != "post" && kind.String != "comment") || !sourceID.Valid || !postID.Valid ||
			sourceID.Int64 < 1 || sourceID.Int64 > maxGroupEvidenceInteger || postID.Int64 < 1 || postID.Int64 > maxGroupEvidenceInteger ||
			(kind.String == "post" && sourceID.Int64 != postID.Int64) || !excerpt.Valid || excerpt.String == "" ||
			!utf8.ValidString(excerpt.String) || utf8.RuneCountInString(excerpt.String) > 400 {
			return groupEvidence{}, errSessionStore
		}
		evidence.Examples = append(evidence.Examples, groupEvidenceExample{
			Kind: kind.String, SourceID: sourceID.Int64, PostID: postID.Int64, Excerpt: excerpt.String,
		})
	}
	if rows.Err() != nil {
		return groupEvidence{}, errSessionStore
	}
	if rowCount == 0 {
		return groupEvidence{}, errConversationForbidden
	}
	return evidence, nil
}
