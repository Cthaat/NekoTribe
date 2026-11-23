package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
)

type groupSentimentWindow struct {
	WindowStart string `json:"window_start"`
	WindowEnd   string `json:"window_end"`
	SampleSize  int    `json:"sample_size"`
	Positive    int    `json:"positive"`
	Neutral     int    `json:"neutral"`
	Negative    int    `json:"negative"`
}

type groupSentimentReport struct {
	Status              string               `json:"status"`
	Current             groupSentimentWindow `json:"current"`
	Previous            groupSentimentWindow `json:"previous"`
	NegativeShareChange *float64             `json:"negative_share_change"`
}

func groupSentimentSampleCount(evidence groupEvidence) int {
	return min(len(evidence.Examples), sentimentContract.SamplePerWindow)
}

func groupSentimentSourceDigest(current, previous groupEvidence) string {
	current.Examples = current.Examples[:groupSentimentSampleCount(current)]
	previous.Examples = previous.Examples[:groupSentimentSampleCount(previous)]
	digest := sha256.Sum256([]byte(groupEvidenceDigest(current) + "\n" + groupEvidenceDigest(previous)))
	return hex.EncodeToString(digest[:])
}

func summarizeGroupSentimentWindow(evidence groupEvidence, signals []sentimentSignal) groupSentimentWindow {
	window := groupSentimentWindow{WindowStart: evidence.WindowStart, WindowEnd: evidence.WindowEnd, SampleSize: len(signals)}
	for _, signal := range signals {
		switch signal.Label {
		case "positive":
			window.Positive++
		case "neutral":
			window.Neutral++
		case "negative":
			window.Negative++
		}
	}
	return window
}

func summarizeGroupSentiment(current, previous groupEvidence, signals []sentimentSignal) groupSentimentReport {
	boundary := groupSentimentSampleCount(current)
	report := groupSentimentReport{Status: "available", Current: summarizeGroupSentimentWindow(current, signals[:boundary]),
		Previous: summarizeGroupSentimentWindow(previous, signals[boundary:])}
	if boundary > 0 && report.Previous.SampleSize > 0 {
		change := float64(report.Current.Negative)/float64(boundary) - float64(report.Previous.Negative)/float64(report.Previous.SampleSize)
		report.NegativeShareChange = &change
	}
	return report
}

type groupSentimentEvidenceStore interface {
	loadGroupSentimentWindow(context.Context, int64, string, groupEvidenceQuery, moderationPolicy) (groupEvidence, error)
}

func (s OracleSessions) loadGroupSentimentWindow(ctx context.Context, actor int64, id string, query groupEvidenceQuery, policy moderationPolicy) (groupEvidence, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return groupEvidence{}, errSessionStore
	}
	defer tx.Rollback()
	record, err := readConversationRow(ctx, tx, actor, id, policy, false)
	if err != nil {
		return groupEvidence{}, err
	}
	if record.Purpose != "group" || record.GroupID == nil {
		return groupEvidence{}, errConversationForbidden
	}
	return readGroupEvidence(ctx, tx, actor, *record.GroupID, query)
}

func groupSentimentEvidenceQuery(kind string, term *string, matchExcerpt bool, current groupEvidence) groupEvidenceQuery {
	return groupEvidenceQuery{LookbackDays: groupDraftContract.LookbackDays[kind], SearchTerm: term, MatchExcerpt: matchExcerpt, WindowEnd: &current.WindowStart}
}

func groupSentiment(ctx context.Context, store groupDraftStore, client *sentimentClient, actor int64, id string, policy moderationPolicy, request groupDraftRequest, current groupEvidence) (*groupSentimentReport, string) {
	lookup, supported := store.(groupSentimentEvidenceStore)
	if !supported || !client.available() {
		return nil, ""
	}
	bounded, cancel := context.WithTimeout(ctx, sentimentTimeout())
	defer cancel()
	query := groupSentimentEvidenceQuery(request.Kind, request.searchTerm, request.searchTerm != nil, current)
	previous, err := lookup.loadGroupSentimentWindow(bounded, actor, id, query, policy)
	if err != nil {
		return nil, ""
	}
	texts := make([]string, 0, sentimentContract.MaxSamples)
	for _, window := range []groupEvidence{current, previous} {
		for _, row := range window.Examples[:groupSentimentSampleCount(window)] {
			texts = append(texts, row.Excerpt)
		}
	}
	signals, ok := client.predictBatch(bounded, texts)
	if !ok {
		return nil, ""
	}
	report := summarizeGroupSentiment(current, previous, signals)
	return &report, groupSentimentSourceDigest(current, previous)
}
