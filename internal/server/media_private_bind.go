package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type privateMediaBindingQueries struct {
	Chat     string `json:"chat"`
	Post     string `json:"post"`
	Retained string `json:"retained"`
}

var privateMediaBinding = func() privateMediaBindingQueries {
	var queries privateMediaBindingQueries
	if json.Unmarshal(contracts.MediaPrivateBind, &queries) != nil ||
		queries.Chat == "" || queries.Post == "" || queries.Retained == "" {
		panic("invalid private media bind contract")
	}
	return queries
}()

func postMediaBindingScope(visibility string) string {
	switch visibility {
	case "private", "followers", "mentioned":
		return "post"
	default:
		return ""
	}
}

// Check private attachment eligibility after locking the asset row. Public
// assets use the legacy table layout, which has no access_scope column.
func checkPrivateMediaBinding(ctx context.Context, tx *sql.Tx, key, scope string, media sql.NamedArg, postID int64, unavailable error) error {
	first, _, _ := strings.Cut(strings.ReplaceAll(key, `\`, "/"), "/")
	if !strings.EqualFold(first, "private") {
		return nil
	}
	if _, err := normalizePrivateMediaStorageKey(key, scope); err != nil {
		return unavailable
	}
	query, args := privateMediaBinding.Chat, []any{media}
	if scope == "post" {
		query = privateMediaBinding.Post
		args = append(args, sql.Named("post_id", postID))
	}
	var permitted int
	err := tx.QueryRowContext(ctx, query, args...).Scan(&permitted)
	if errors.Is(err, sql.ErrNoRows) || (err != nil && privateMediaSchemaMissing(err)) {
		return unavailable
	}
	if err != nil {
		return errSessionStore
	}
	if permitted != 1 {
		return unavailable
	}
	linked, err := directAssetLinked(ctx, tx, media)
	if err != nil {
		return err
	}
	if linked {
		return unavailable
	}
	return nil
}

func rejectRetainedPrivatePostMedia(ctx context.Context, tx *sql.Tx, postID int64) error {
	var found int
	err := tx.QueryRowContext(ctx, privateMediaBinding.Retained, sql.Named("post_id", postID)).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return errSessionStore
	}
	return errPostUpdateMedia
}
