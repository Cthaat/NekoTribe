package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime"
	"net/http"
	"strings"
)

func wantsAIEventStream(r *http.Request) bool {
	for _, value := range strings.Split(r.Header.Get("Accept"), ",") {
		kind, params, _ := mime.ParseMediaType(strings.TrimSpace(value))
		if kind == "text/event-stream" && params["q"] != "0" {
			return true
		}
	}
	return false
}

// A generation handler retains its existing JSON responder. After the stream
// starts, that response becomes the final SSE event instead of a second status.
type aiStreamResponse struct {
	http.ResponseWriter
	started bool
	status  int
}

func (w *aiStreamResponse) start() {
	if w.started {
		return
	}
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Accel-Buffering", "no")
	w.ResponseWriter.WriteHeader(http.StatusOK)
	w.started = true
}

func (w *aiStreamResponse) send(event string, data []byte) error {
	w.start()
	if _, err := fmt.Fprintf(w.ResponseWriter, "event: %s\ndata: %s\n\n", event, data); err != nil {
		return err
	}
	return http.NewResponseController(w.ResponseWriter).Flush()
}

func (w *aiStreamResponse) delta(text string) error {
	data, err := json.Marshal(struct {
		Text string `json:"text"`
	}{text})
	if err != nil {
		return err
	}
	return w.send("delta", data)
}

func (w *aiStreamResponse) WriteHeader(status int) {
	w.status = status
	if !w.started && status >= 400 {
		w.ResponseWriter.WriteHeader(status)
	}
}

func (w *aiStreamResponse) Write(data []byte) (int, error) {
	if !w.started && w.status >= 400 {
		return w.ResponseWriter.Write(data)
	}
	event := "done"
	if w.status >= 400 {
		event = "failed"
	}
	if err := w.send(event, bytes.TrimSpace(data)); err != nil {
		return 0, err
	}
	return len(data), nil
}
