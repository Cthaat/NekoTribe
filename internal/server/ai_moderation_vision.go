package server

import (
	"context"
	"database/sql"
	"errors"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

func moderationHasImages(kind string) bool {
	return kind == "post" || kind == "group_post"
}

func moderationImageQuery(kind string, multiple bool) string {
	key := "moderation_image"
	if kind == "group_post" {
		key = "moderation_group_image"
	}
	if multiple {
		key += "s"
	}
	return visionContract.SQL[key]
}

func readModerationVisionImages(ctx context.Context, tx *sql.Tx, actor int64, target moderationTargetReference) ([]storedVisionImage, error) {
	rows, err := tx.QueryContext(ctx, moderationImageQuery(target.Kind, true), sql.Named("viewer_id", actor), sql.Named("post_id", target.PostID))
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	images := make([]storedVisionImage, 0, ai.MaxVisionImages)
	for rows.Next() {
		image, err := scanVisionImage(rows)
		if err != nil || len(images) == ai.MaxVisionImages {
			return nil, errSessionStore
		}
		images = append(images, image)
	}
	if rows.Err() != nil {
		return nil, errSessionStore
	}
	return images, nil
}

func eligibleModerationVisionImage(image storedVisionImage) bool {
	_, keyErr := image.storageKey()
	return validVisionMediaID(image.ID) && image.Scope == "public" && image.validTypeAndSize() && keyErr == nil
}

func moderationVisionInputs(ctx context.Context, storage LocalStorageConfig, rows []storedVisionImage) ([]ai.VisionImage, []visionImageReference) {
	var inputs []ai.VisionImage
	var refs []visionImageReference
	seen := make(map[int64]bool, len(rows))
	remaining := int64(ai.MaxVisionTotalBytes)
	for _, row := range rows {
		if len(inputs) >= ai.MaxVisionImages {
			break
		}
		if seen[row.ID] || row.Size > remaining || !eligibleModerationVisionImage(row) {
			continue
		}
		image, err := readStoredVisionImage(ctx, storage, row)
		if err != nil {
			continue
		}
		seen[row.ID] = true
		remaining -= int64(len(image.Data))
		inputs = append(inputs, image)
		refs = append(refs, row.reference())
	}
	return inputs, refs
}

func validModerationImageReferences(refs []visionImageReference) bool {
	if len(refs) == 0 || len(refs) > ai.MaxVisionImages {
		return false
	}
	seen := make(map[int64]bool, len(refs))
	for _, ref := range refs {
		if !validVisionMediaID(ref.MediaID) || !moderationDigestHex(ref.Version) || seen[ref.MediaID] {
			return false
		}
		seen[ref.MediaID] = true
	}
	return true
}

func validateModerationImageReferences(refs []visionImageReference, rows []storedVisionImage) error {
	if !validModerationImageReferences(refs) || len(refs) != len(rows) {
		return errConversationConflict
	}
	var total int64
	for i, row := range rows {
		if !eligibleModerationVisionImage(row) || row.reference() != refs[i] {
			return errConversationConflict
		}
		total += row.Size
	}
	if total > ai.MaxVisionTotalBytes {
		return errConversationConflict
	}
	return nil
}

func recheckModerationVisionImages(ctx context.Context, tx *sql.Tx, actor int64, record *moderationAdviceRecord) error {
	if !moderationHasImages(record.Target.Kind) || !validModerationImageReferences(record.ImageSources) {
		return errConversationConflict
	}
	rows := make([]storedVisionImage, 0, len(record.ImageSources))
	for _, ref := range record.ImageSources {
		row, err := scanVisionImage(tx.QueryRowContext(ctx, moderationImageQuery(record.Target.Kind, false), sql.Named("viewer_id", actor), sql.Named("post_id", record.Target.PostID), sql.Named("media_id", ref.MediaID)))
		if errors.Is(err, sql.ErrNoRows) {
			return errConversationConflict
		}
		if err != nil {
			return errSessionStore
		}
		rows = append(rows, row)
	}
	return validateModerationImageReferences(record.ImageSources, rows)
}

func (s OracleSessions) verifyModerationVisionInputs(ctx context.Context, actor int64, record *moderationAdviceRecord) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return errSessionStore
	}
	defer tx.Rollback()
	if _, err := currentModerationAdvice(ctx, tx, actor, record, false); err != nil {
		return err
	}
	if err := tx.Rollback(); err != nil {
		return errSessionStore
	}
	return nil
}
