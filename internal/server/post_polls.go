package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type postPollPolicy struct {
	MaxOptionBytes int `json:"max_option_bytes"`
	MinOptions     int `json:"min_options"`
	MaxOptions     int `json:"max_options"`
	SQL            struct {
		InsertPoll      string `json:"insert_poll"`
		InsertOption    string `json:"insert_option"`
		Read            string `json:"read"`
		InsertBallot    string `json:"insert_ballot"`
		InsertVote      string `json:"insert_vote"`
		AnyTablePresent string `json:"any_table_present"`
	} `json:"sql"`
}

var postPollsContract = func() postPollPolicy {
	var policy postPollPolicy
	if json.Unmarshal(contracts.PostPolls, &policy) != nil || policy.MaxOptionBytes < 1 ||
		policy.MinOptions < 2 || policy.MaxOptions < policy.MinOptions {
		panic("invalid post polls contract")
	}
	return policy
}()

var (
	errPostPollUnavailable = errors.New("post poll schema unavailable")
	errPostPollMissing     = errors.New("post or poll not found")
	errPostPollForbidden   = errors.New("group poll voting forbidden")
	errPostPollInvalid     = errors.New("post poll input invalid")
	errPostPollCutoff      = errors.New("post poll cutoff is not in the future")
	errPostPollClosed      = errors.New("post poll closed")
	errPostPollVoted       = errors.New("post poll ballot already recorded")
	postUTCDatePattern     = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)
)

const postUTCDateLayout = "2006-01-02T15:04:05.000Z"

func parsePostUTCDate(value string) (time.Time, bool) {
	if !postUTCDatePattern.MatchString(value) {
		return time.Time{}, false
	}
	instant, err := time.Parse(time.RFC3339, value)
	instant = instant.UTC().Truncate(time.Millisecond)
	return instant, err == nil && instant.Year() >= 1 && instant.Year() <= 9999
}

type postPollCreation struct {
	options  []string
	multiple bool
	closesAt time.Time
}

type postPollOption struct {
	ID      int64   `json:"option_id"`
	Text    string  `json:"text"`
	Votes   int64   `json:"votes_count"`
	Percent float64 `json:"percent"`
}

type postPoll struct {
	ID           int64            `json:"poll_id"`
	Multiple     bool             `json:"multiple"`
	ClosesAt     string           `json:"closes_at"`
	Closed       bool             `json:"closed"`
	TotalBallots int64            `json:"total_ballots"`
	MyOptionIDs  []int64          `json:"my_option_ids"`
	Options      []postPollOption `json:"options"`
}

type postPollTarget struct {
	group, post int64
}

func parsePostPollCreation(value any) (*postPollCreation, error) {
	body, object := value.(map[string]any)
	options, array := body["options"].([]any)
	multiple, boolean := body["multiple"].(bool)
	cutoff, stringValue := body["closes_at"].(string)
	if !object || len(body) != 3 || !array || len(options) < postPollsContract.MinOptions ||
		len(options) > postPollsContract.MaxOptions || !boolean || !stringValue {
		return nil, errPostPollInvalid
	}
	closesAt, valid := parsePostUTCDate(cutoff)
	if !valid {
		return nil, errPostPollInvalid
	}
	poll := &postPollCreation{options: make([]string, 0, len(options)), multiple: multiple, closesAt: closesAt}
	for _, raw := range options {
		text, ok := raw.(string)
		text = strings.TrimFunc(text, jsTrimSpace)
		if !ok || text == "" || !utf8.ValidString(text) || len(text) > postPollsContract.MaxOptionBytes || slices.Contains(poll.options, text) {
			return nil, errPostPollInvalid
		}
		poll.options = append(poll.options, text)
	}
	return poll, nil
}

func checkPostPollSchema(ctx context.Context, db schemaQueryer) error {
	var catalog schemaCatalog
	if json.Unmarshal(contracts.PostPollsSchemaCatalog, &catalog) != nil || validateFeatureSchema(ctx, db, catalog, "post-polls") != nil {
		return errPostPollUnavailable
	}
	return nil
}

func (s OracleSessions) openPostPollConnection(ctx context.Context) (*sql.Conn, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errSessionStore
	}
	if err := checkPostPollSchema(ctx, conn); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

func insertPostPoll(ctx context.Context, tx *sql.Tx, target postPollTarget, poll *postPollCreation) error {
	var pollID int64
	if tx.QueryRowContext(ctx, "SELECT seq_post_poll_id.NEXTVAL FROM dual").Scan(&pollID) != nil || pollID < 1 || pollID > maxSocketID {
		return errSessionStore
	}
	var postID, groupPostID any
	if target.group == 0 {
		postID = target.post
	} else {
		groupPostID = target.post
	}
	multiple := 0
	if poll.multiple {
		multiple = 1
	}
	bind := sql.Named("poll_id", pollID)
	n, err := postTxExecute(ctx, tx, postPollsContract.SQL.InsertPoll, bind, sql.Named("post_id", postID),
		sql.Named("group_post_id", groupPostID), sql.Named("allow_multiple", multiple),
		sql.Named("closes_at", poll.closesAt.Format(postUTCDateLayout)))
	if err != nil {
		return err
	}
	if n == 0 {
		return errPostPollCutoff
	}
	if n != 1 {
		return errSessionStore
	}
	for i, text := range poll.options {
		if err := writeOneChatRow(ctx, tx, postPollsContract.SQL.InsertOption, bind,
			sql.Named("option_id", i+1), sql.Named("option_text", text)); err != nil {
			return err
		}
	}
	return nil
}

func readPostPoll(ctx context.Context, db groupDetailQueryer, viewer *int64, target postPollTarget, allowLegacy bool) (*postPoll, error) {
	isGroup := 0
	if target.group != 0 {
		isGroup = 1
	}
	rows, err := db.QueryContext(ctx, postPollsContract.SQL.Read, sql.Named("viewer_id", nullableViewer(viewer)),
		sql.Named("is_group", isGroup), sql.Named("post_id", target.post))
	if err != nil {
		if allowLegacy && oracleErrorCode(err, "ORA-00942") && schemaOwnerMatches(ctx, db) {
			var present int
			if errors.Is(db.QueryRowContext(ctx, postPollsContract.SQL.AnyTablePresent).Scan(&present), sql.ErrNoRows) {
				return nil, nil
			}
		}
		if privateMediaSchemaMissing(err) {
			return nil, errPostPollUnavailable
		}
		return nil, errSessionStore
	}
	defer rows.Close()
	poll := postPoll{MyOptionIDs: []int64{}, Options: []postPollOption{}}
	for rows.Next() {
		var option postPollOption
		var multiple, closed, selected int
		if err := rows.Scan(&poll.ID, &multiple, &poll.ClosesAt, &closed, &option.ID, &option.Text,
			&poll.TotalBallots, &option.Votes, &selected); err != nil {
			return nil, errSessionStore
		}
		poll.Multiple, poll.Closed = multiple == 1, closed == 1
		if poll.TotalBallots > 0 {
			option.Percent = math.Round(float64(option.Votes)*1000/float64(poll.TotalBallots)) / 10
		}
		if selected == 1 {
			poll.MyOptionIDs = append(poll.MyOptionIDs, option.ID)
		}
		poll.Options = append(poll.Options, option)
	}
	if rows.Err() != nil {
		return nil, errSessionStore
	}
	if len(poll.Options) == 0 {
		return nil, nil
	}
	return &poll, nil
}

type postPollHydrator interface {
	ReadAttachedPostPoll(context.Context, *int64, int64) (*postPoll, error)
}

func (s OracleSessions) ReadAttachedPostPoll(ctx context.Context, viewer *int64, post int64) (*postPoll, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, errSessionStore
	}
	defer conn.Close()
	return readPostPoll(ctx, conn, viewer, postPollTarget{post: post}, true)
}
