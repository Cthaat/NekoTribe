package server

import (
	"context"
	"database/sql"
	"errors"
)

type contentQueueSentimentSource interface {
	readContentQueueSentiment(context.Context, int64, int64) (string, error)
}

func (s OracleSessions) readContentQueueSentiment(ctx context.Context, viewer, postID int64) (string, error) {
	var excerpt sql.NullString
	err := s.DB.QueryRowContext(ctx, sentimentContract.QueuePostQuery, sql.Named("viewer_id", viewer), sql.Named("post_id", postID)).Scan(&excerpt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return excerpt.String, err
}

func addContentQueueSentiment(ctx context.Context, source contentQueueSentimentSource, client *sentimentClient, viewer int64, items []contentQueueItem) {
	if !client.available() || len(items) == 0 {
		return
	}
	bounded, cancel := context.WithTimeout(ctx, sentimentTimeout())
	defer cancel()
	texts := make([]string, 0, sentimentContract.MaxSamples)
	indices := make([]int, 0, sentimentContract.MaxSamples)
	for i, item := range items {
		if len(texts) == sentimentContract.MaxSamples || bounded.Err() != nil {
			break
		}
		if item.PostID < 1 || item.PostID > 9007199254740991 {
			continue
		}
		excerpt, err := source.readContentQueueSentiment(bounded, viewer, item.PostID)
		if err != nil {
			return
		}
		if !validSentimentExcerpt(excerpt) {
			continue
		}
		texts = append(texts, excerpt)
		indices = append(indices, i)
	}
	if signals, ok := client.predictBatch(bounded, texts); ok {
		for j, index := range indices {
			items[index].SentimentSignal = &signals[j]
		}
	}
}
