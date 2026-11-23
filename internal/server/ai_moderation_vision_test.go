package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
)

type moderationVisionFixture struct {
	target       moderationTargetReference
	image        storedVisionImage
	text, digest string
	imageQueries int
	lost         bool
	driverState
}

type moderationVisionConnector struct{ state *moderationVisionFixture }
type moderationVisionConn struct {
	*testConn
	state *moderationVisionFixture
}

func (c moderationVisionConnector) Connect(context.Context) (driver.Conn, error) {
	return &moderationVisionConn{testConn: &testConn{&c.state.driverState}, state: c.state}, nil
}
func (moderationVisionConnector) Driver() driver.Driver { return testDriver{} }

func (c *moderationVisionConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	s := c.state
	switch {
	case query == moderationAdviceContract.Queries[s.target.Kind]:
		var group driver.Value
		if s.target.GroupID != nil {
			group = *s.target.GroupID
		}
		return &alertRows{values: []driver.Value{s.target.PostID, group, s.text, int64(len(s.text))}}, nil
	case strings.Contains(query, "FROM n_ai_terms_active"):
		return &alertRows{values: []driver.Value{s.digest, int64(1), int64(1)}}, nil
	case query == moderationImageQuery(s.target.Kind, false):
		s.imageQueries++
		bind := make(map[string]driver.Value, len(args))
		for _, arg := range args {
			bind[arg.Name] = arg.Value
		}
		if bind["post_id"] != s.target.PostID || bind["viewer_id"] != int64(42) || bind["media_id"] != s.image.ID {
			return nil, errors.New("unexpected eligibility scope")
		}
		if s.lost {
			return emptyRows{&s.driverState}, nil
		}
		return &alertRows{values: []driver.Value{s.image.ID, s.image.Key, s.image.Scope, s.image.MIME, s.image.Size}}, nil
	default:
		return nil, errors.New("unexpected database query")
	}
}

func TestVisionModerationHistoryRechecksExactAttachment(t *testing.T) {
	_, digest := termsAuthorityFixtures(t)
	for _, kind := range []string{"post", "group_post"} {
		t.Run(kind, func(t *testing.T) {
			state := &moderationVisionFixture{target: moderationTargetReference{Kind: kind, ID: 20, PostID: 20}, digest: digest,
				image: storedVisionImage{ID: 17, Key: "posts/images/42/picture.jpg", Scope: "public", MIME: "image/jpeg", Size: 100}}
			if kind == "group_post" {
				group := int64(7)
				state.target.GroupID = &group
			}
			state.target.Digest = targetDigest(state.target, "")
			record := &moderationAdviceRecord{Version: 2, Target: state.target, Locale: "zh", TermsDigest: digest, TermsGeneration: 1,
				Advice: moderationOpinion{Reason: "visual evidence", RuleIDs: []int64{1}}, ImageSources: []visionImageReference{state.image.reference()}}
			db := sql.OpenDB(moderationVisionConnector{state})
			defer db.Close()
			ctx := context.Background()
			tx, err := db.BeginTx(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback()
			result, err := currentModerationAdvice(ctx, tx, 42, record, false)
			if err != nil || result == nil || result.AnalysisMode != "text_and_images" || state.imageQueries != 1 {
				t.Fatal(result, err, state.imageQueries)
			}
			state.lost = true
			result, err = currentModerationAdvice(ctx, tx, 42, record, true)
			if !errors.Is(err, errConversationConflict) || result != nil || state.imageQueries != 2 {
				t.Fatal(result, err, state.imageQueries)
			}
		})
	}
}
