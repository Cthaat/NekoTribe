package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type postMarkdownPolicy struct {
	MaxBytes int               `json:"max_markdown_bytes"`
	SQL      map[string]string `json:"sql"`
}

var postMarkdown = func() postMarkdownPolicy {
	var policy postMarkdownPolicy
	if json.Unmarshal(contracts.PostMarkdown, &policy) != nil || policy.MaxBytes < 1 {
		panic("invalid post Markdown contract")
	}
	return policy
}()

var (
	errPostMarkdownInvalid     = errors.New("post Markdown input invalid")
	errPostMarkdownUnavailable = errors.New("post Markdown schema unavailable")
)

type postMarkdownEdit struct {
	body *string
}

func parsePostMarkdown(value any) (*string, error) {
	text, ok := value.(string)
	if !ok || len(text) > postMarkdown.MaxBytes || !utf8.ValidString(text) || strings.TrimFunc(text, jsTrimSpace) == "" {
		return nil, errPostMarkdownInvalid
	}
	return &text, nil
}

func checkPostMarkdownSchema(ctx context.Context, db schemaQueryer) error {
	var catalog schemaCatalog
	if json.Unmarshal(contracts.PostMarkdownSchemaCatalog, &catalog) != nil ||
		validateFeatureSchema(ctx, db, catalog, "post-markdown") != nil {
		return errPostMarkdownUnavailable
	}
	return nil
}

func checkPostCreationExtras(ctx context.Context, db schemaQueryer, poll *postPollCreation, markdown *string) error {
	if poll != nil {
		if err := checkPostPollSchema(ctx, db); err != nil {
			return err
		}
	}
	if markdown != nil {
		return checkPostMarkdownSchema(ctx, db)
	}
	return nil
}

func insertPostMarkdown(ctx context.Context, tx *sql.Tx, post int64, isGroup bool, markdown string) error {
	var postID, groupPostID any
	if isGroup {
		groupPostID = post
	} else {
		postID = post
	}
	return writeOneChatRow(ctx, tx, postMarkdown.SQL["insert"], sql.Named("post_id", postID),
		sql.Named("group_post_id", groupPostID), sql.Named("markdown_body", markdown))
}

func updatePostMarkdown(ctx context.Context, tx *sql.Tx, post int64, edit postMarkdownEdit) error {
	id := sql.Named("post_id", post)
	if edit.body == nil {
		removed, err := postTxExecute(ctx, tx, postMarkdown.SQL["remove"], id)
		if err != nil || removed < 0 || removed > 1 {
			return errSessionStore
		}
		return nil
	}
	updated, err := postTxExecute(ctx, tx, postMarkdown.SQL["update"], id, sql.Named("markdown_body", *edit.body))
	if err != nil || updated < 0 || updated > 1 {
		return errSessionStore
	}
	if updated == 0 {
		return insertPostMarkdown(ctx, tx, post, false, *edit.body)
	}
	return nil
}

func readPostMarkdown(ctx context.Context, db groupDetailQueryer, post int64, isGroup bool) (*string, error) {
	scope := 0
	if isGroup {
		scope = 1
	}
	var body string
	err := db.QueryRowContext(ctx, postMarkdown.SQL["read"], sql.Named("is_group", scope), sql.Named("post_id", post)).Scan(&body)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if oracleErrorCode(err, "ORA-00942") && schemaOwnerMatches(ctx, db) {
		var present int
		if errors.Is(db.QueryRowContext(ctx, postMarkdown.SQL["present"]).Scan(&present), sql.ErrNoRows) {
			return nil, nil
		}
	}
	if privateMediaSchemaMissing(err) {
		return nil, errPostMarkdownUnavailable
	}
	if err != nil {
		return nil, errSessionStore
	}
	return &body, nil
}

type postMarkdownHydrator interface {
	ReadAttachedPostMarkdown(context.Context, int64) (*string, error)
}

func (s OracleSessions) ReadAttachedPostMarkdown(ctx context.Context, post int64) (*string, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errSessionStore
	}
	defer conn.Close()
	return readPostMarkdown(ctx, conn, post, false)
}

func postMarkdownFailure(err error) *postFailure {
	switch {
	case errors.Is(err, errPostMarkdownUnavailable):
		return &postFailure{503, "长文服务暂不可用"}
	case errors.Is(err, errPostMarkdownInvalid):
		return &postFailure{400, "markdown 参数错误"}
	default:
		return &postFailure{500, "服务器内部错误"}
	}
}
