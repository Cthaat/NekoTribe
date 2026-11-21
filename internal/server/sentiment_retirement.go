package server

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

var sentimentRetirement = func() struct {
	Prefix, ConfigMessage, RetiredMessage string
	Config                                json.RawMessage
	Operations                            []struct{ Method, Path string }
} {
	var policy struct {
		Prefix, ConfigMessage, RetiredMessage string
		Config                                json.RawMessage
		Operations                            []struct{ Method, Path string }
	}
	if err := json.Unmarshal(contracts.SentimentRetirement, &policy); err != nil || policy.Prefix == "" {
		panic("invalid sentiment retirement contract")
	}
	return policy
}()

func handleRetiredSentiment(w http.ResponseWriter, r *http.Request) bool {
	policy := sentimentRetirement
	path := strings.TrimRight(r.URL.EscapedPath(), "/")
	if path != policy.Prefix && !strings.HasPrefix(path, policy.Prefix+"/") {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	if r.Method == http.MethodGet && path == policy.Prefix+"/config" {
		respond(w, 200, 200, policy.ConfigMessage, policy.Config)
		return true
	}
	relative := strings.TrimPrefix(path, policy.Prefix+"/")
	segments := strings.Split(relative, "/")
	for _, operation := range policy.Operations {
		if operation.Method != r.Method {
			continue
		}
		pattern := strings.Split(operation.Path, "/")
		if len(pattern) != len(segments) {
			continue
		}
		match := true
		for index, part := range pattern {
			if part != segments[index] && !(strings.HasPrefix(part, "{") && strings.HasSuffix(part, "}") && segments[index] != "") {
				match = false
				break
			}
		}
		if match {
			respond(w, http.StatusGone, 41001, policy.RetiredMessage, nil)
			return true
		}
	}
	respond(w, 404, 40404, "API route not found", nil)
	return true
}
