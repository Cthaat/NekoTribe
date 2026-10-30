package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/coder/websocket"
)

func validSocketHandshake(r *http.Request) bool {
	if !strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket") || r.Header.Get("Sec-WebSocket-Version") != "13" {
		return false
	}
	connectionUpgrade := false
	for _, line := range r.Header.Values("Connection") {
		for _, token := range strings.Split(line, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "upgrade") {
				connectionUpgrade = true
			}
		}
	}
	key, err := base64.StdEncoding.DecodeString(r.Header.Get("Sec-WebSocket-Key"))
	return connectionUpgrade && err == nil && len(key) == 16
}

func socketAccessToken(r *http.Request) string {
	if value := r.URL.Query().Get("token"); value != "" {
		return value
	}
	header := strings.TrimSpace(bearerPrefix.ReplaceAllString(r.Header.Get("Authorization"), ""))
	if header != "" {
		return header
	}
	if cookie, err := r.Cookie("access_token"); err == nil {
		if decoded, e := url.PathUnescape(cookie.Value); e == nil {
			return decoded
		}
		return cookie.Value
	}
	return ""
}

func socketOriginAllowed(r *http.Request, policy CorsPolicy) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	if policy.allows(origin) {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil || normalizeOrigin(origin) == "" || u.Host != r.Host {
		return false
	}
	if r.TLS != nil {
		return u.Scheme == "https"
	}
	return u.Scheme == "http"
}

func validPresenceEvent(data map[string]json.RawMessage) bool {
	var id int64
	var status, serverID string
	if json.Unmarshal(data["user_id"], &id) != nil || id <= 0 || id > 9007199254740991 || json.Unmarshal(data["online_status"], &status) != nil || json.Unmarshal(data["server_id"], &serverID) != nil || serverID == "" {
		return false
	}
	if status != "online" && status != "offline" && status != "hidden" {
		return false
	}
	last, exists := data["last_seen_at"]
	if !exists {
		return false
	}
	if string(last) == "null" {
		return true
	}
	var text string
	return status != "hidden" && json.Unmarshal(last, &text) == nil
}

func socketEventMatchesChannel(channel, userChannel string, body []byte) bool {
	var event struct {
		Type      string                     `json:"type"`
		Data      map[string]json.RawMessage `json:"data"`
		Timestamp *float64                   `json:"timestamp"`
	}
	if json.Unmarshal(body, &event) != nil || event.Timestamp == nil || event.Data == nil {
		return false
	}
	return (channel == userChannel && isNotificationEvent(event.Type)) || (channel == "ws:presence" && event.Type == "presence_update" && validPresenceEvent(event.Data))
}

func notificationWebSocket(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, cors CorsPolicy, source NotificationEventSource) {
	if !validSocketHandshake(r) {
		respond(w, 400, 40001, "请求参数错误", nil)
		return
	}
	if !socketOriginAllowed(r, cors) {
		respond(w, 403, 40301, "Forbidden", nil)
		return
	}
	token := socketAccessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	if n, e := repository.Touch(r.Context(), claims); e != nil || n != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	if source == nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	events, stop, err := source.Subscribe(ctx, claims.UserID)
	if err != nil || events == nil || stop == nil {
		if stop != nil {
			stop()
		}
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	defer stop()
	// Origin was checked against the exact application policy above.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(65536)
	id, err := randomUUID()
	if err != nil {
		return
	}
	write := func(kind string, data map[string]interface{}) bool {
		body, e := json.Marshal(map[string]interface{}{"type": kind, "data": data, "timestamp": time.Now().UnixMilli()})
		if e != nil {
			return false
		}
		writeCtx, finish := context.WithTimeout(ctx, 5*time.Second)
		defer finish()
		return conn.Write(writeCtx, websocket.MessageText, body) == nil
	}
	if !write("system_notification", map[string]interface{}{"message": "WebSocket connected", "session_id": "ws_" + id, "user_id": claims.UserID}) {
		return
	}
	type incoming struct{ body []byte }
	in := make(chan incoming, 1)
	go func() {
		defer close(in)
		for {
			kind, body, e := conn.Read(ctx)
			if e != nil {
				return
			}
			if kind != websocket.MessageText {
				continue
			}
			select {
			case in <- incoming{body: body}:
			case <-ctx.Done():
				return
			}
		}
	}()
	alive := func() bool {
		current, e := codec.Verify(token, auth.Access)
		if e != nil || current.UserID != claims.UserID || current.SessionID != claims.SessionID {
			return false
		}
		n, e := repository.Touch(ctx, current)
		return e == nil && n == 1
	}
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if !alive() {
				return
			}
		case message, ok := <-in:
			if !ok {
				return
			}
			var value struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(message.body, &value) != nil {
				if strings.Contains(string(message.body), "ping") {
					value.Type = "ping"
				} else {
					if !write("error", map[string]interface{}{"message": "消息格式错误"}) {
						return
					}
					continue
				}
			}
			if value.Type == "ping" {
				if !alive() {
					return
				}
				if !write("pong", map[string]interface{}{"timestamp": time.Now().UnixMilli()}) {
					return
				}
			} else if !write("error", map[string]interface{}{"message": "不支持的 WebSocket 消息类型", "type": value.Type}) {
				return
			}
		case body, ok := <-events:
			if !ok {
				return
			}
			if len(body) > 262144 {
				continue
			}
			var event struct {
				Type      string                     `json:"type"`
				Data      map[string]json.RawMessage `json:"data"`
				Timestamp *float64                   `json:"timestamp"`
			}
			if json.Unmarshal(body, &event) != nil || event.Data == nil || event.Timestamp == nil || (!isNotificationEvent(event.Type) && !(event.Type == "presence_update" && validPresenceEvent(event.Data))) {
				continue
			}
			if !alive() {
				return
			}
			writeCtx, finish := context.WithTimeout(ctx, 5*time.Second)
			err = conn.Write(writeCtx, websocket.MessageText, body)
			finish()
			if err != nil {
				return
			}
		}
	}
}
