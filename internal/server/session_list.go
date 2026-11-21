package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"math"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type SessionPage struct{ Page, PageSize, Start, End float64 }
type SessionItem struct {
	SessionID      string `json:"session_id"`
	DeviceInfo     string `json:"device_info"`
	IPAddress      string `json:"ip_address"`
	LastAccessedAt string `json:"last_accessed_at"`
	CreatedAt      string `json:"created_at"`
	IsCurrent      bool   `json:"is_current"`
}
type sessionListRepository interface {
	ListSessions(context.Context, int64, SessionPage) ([]SessionItem, int64, error)
}

var decimalNumber = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)
var radixNumber = regexp.MustCompile(`^0(?:[xX][0-9a-fA-F]+|[bB][01]+|[oO][0-7]+)$`)

// H3 keeps a parameter when percent decoding fails, so it still counts as a
// duplicate. net/url.ParseQuery drops malformed parameters instead.
func parseSessionQuery(raw string) url.Values {
	values := make(url.Values)
	decode := func(value string) string {
		value = strings.ReplaceAll(value, "+", " ")
		decoded, err := url.PathUnescape(value)
		if err != nil || !utf8.ValidString(decoded) {
			return value
		}
		return decoded
	}
	for _, part := range strings.Split(raw, "&") {
		if part == "" {
			continue
		}
		key, value, _ := strings.Cut(part, "=")
		if key == "" {
			continue
		}
		values.Add(decode(key), decode(value))
	}
	return values
}

func sessionQueryNumber(values url.Values, key string, fallback float64) float64 {
	v := values[key]
	if len(v) != 1 {
		return fallback
	}
	text := strings.TrimFunc(v[0], jsTrimSpace)
	var number float64
	if radixNumber.MatchString(text) {
		radix := 16
		switch text[1] {
		case 'b', 'B':
			radix = 2
		case 'o', 'O':
			radix = 8
		}
		n, ok := new(big.Int).SetString(text[2:], radix)
		if !ok {
			return fallback
		}
		number, _ = new(big.Float).SetInt(n).Float64()
	} else if decimalNumber.MatchString(text) {
		n, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return fallback
		}
		number = n
	} else {
		return fallback
	}
	if math.IsInf(number, 0) || math.IsNaN(number) || number <= 0 {
		return fallback
	}
	return number
}
func sessionPagination(values url.Values) SessionPage {
	page := math.Min(math.Max(sessionQueryNumber(values, "page", 1), 1), 10000)
	size := math.Min(math.Max(sessionQueryNumber(values, "page_size", 20), 1), 100)
	return SessionPage{Page: page, PageSize: size, Start: (page-1)*size + 1, End: page * size}
}

const sessionListSQL = `WITH eligible AS (
  SELECT session_id, device_info, ip_address, last_accessed_at, created_at,
         ROW_NUMBER() OVER (ORDER BY last_accessed_at DESC, session_id ASC) AS rn
  FROM n_auth_sessions
  WHERE user_id = :user_id AND revoked_at IS NULL
)
SELECT t.total, e.session_id, e.device_info, e.ip_address, e.last_accessed_at, e.created_at
FROM (SELECT COUNT(*) AS total FROM eligible) t
LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row
ORDER BY e.rn`

func (s OracleSessions) ListSessions(ctx context.Context, user int64, page SessionPage) (items []SessionItem, total int64, err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return nil, 0, errSessionStore
	}
	defer func() {
		if e := conn.Close(); e != nil {
			items = nil
			total = 0
			err = errSessionStore
		}
	}()
	rows, e := conn.QueryContext(ctx, sessionListSQL, sql.Named("user_id", user), sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if e != nil {
		return nil, 0, errSessionStore
	}
	defer func() {
		if e := rows.Close(); e != nil {
			items = nil
			total = 0
			err = errSessionStore
		}
	}()
	items = make([]SessionItem, 0)
	for rows.Next() {
		var id, device, ip sql.NullString
		var last, created sql.NullTime
		if e = rows.Scan(&total, &id, &device, &ip, &last, &created); e != nil {
			return nil, 0, errSessionStore
		}
		if !id.Valid {
			continue
		}
		item := SessionItem{SessionID: id.String, DeviceInfo: device.String, IPAddress: ip.String}
		if value := profileDate(last); value != nil {
			item.LastAccessedAt = *value
		}
		if value := profileDate(created); value != nil {
			item.CreatedAt = *value
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}

func listSessions(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) {
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	affected, err := repository.Touch(r.Context(), claims)
	if err != nil || affected != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	store, ok := repository.(sessionListRepository)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
	items, total, err := store.ListSessions(r.Context(), claims.UserID, page)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if items == nil {
		items = []SessionItem{}
	}
	for i := range items {
		items[i].IsCurrent = items[i].SessionID == claims.SessionID
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(struct {
		Code    int           `json:"code"`
		Message string        `json:"message"`
		Data    []SessionItem `json:"data"`
		Meta    interface{}   `json:"meta"`
	}{200, "success", items, map[string]interface{}{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)}})
}
