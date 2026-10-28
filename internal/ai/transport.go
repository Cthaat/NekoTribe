package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	ErrInvalidRequest          = errors.New("INVALID_REQUEST")
	ErrMissingCredential       = errors.New("MISSING_CREDENTIAL")
	ErrProviderUnavailable     = errors.New("PROVIDER_UNAVAILABLE")
	ErrProviderRejected        = errors.New("PROVIDER_REJECTED")
	ErrInvalidProviderResponse = errors.New("INVALID_PROVIDER_RESPONSE")
	ErrResponseTooLarge        = errors.New("RESPONSE_TOO_LARGE")
	ErrTimeout                 = errors.New("TIMEOUT")
	ErrCancelled               = errors.New("CANCELLED")
)

const transportLimit = 1048576

var toolName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`)

type ToolProposal struct {
	ID        string         `json:"id"`
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}
type InferenceUsage struct {
	InputTokens  *int64 `json:"inputTokens"`
	OutputTokens *int64 `json:"outputTokens"`
}
type InferenceResult struct {
	Text         string         `json:"text"`
	ToolCalls    []ToolProposal `json:"toolCalls"`
	FinishReason string         `json:"finishReason"`
	Usage        InferenceUsage `json:"usage"`
}

// Transport owns its HTTP client; callers cannot bypass redirect/encoding policy.
type Transport struct {
	resolver func(string) (string, error)
	timeout  time.Duration
	client   *http.Client
}

func NewTransport(resolver func(string) (string, error), timeoutMs ...int) (*Transport, error) {
	timeout := 30000
	if len(timeoutMs) > 1 {
		return nil, ErrInvalidRequest
	}
	if len(timeoutMs) == 1 {
		timeout = timeoutMs[0]
	}
	if timeout < 1 || timeout > 300000 {
		return nil, ErrInvalidRequest
	}
	// HTTP/2 can replay a POST after REFUSED_STREAM/GOAWAY internally. Keep
	// this component on HTTP/1 and disable replay of its nonempty request body.
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	tr := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		Protocols:             protocols,
		DisableCompression:    true,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
	return &Transport{resolver: resolver, timeout: time.Duration(timeout) * time.Millisecond, client: &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

// boundedJSON checks nesting and UTF-8 before the JSON parser and accepts only a
// single complete JSON document. Scalars do not contribute to container depth.
func boundedJSON(data []byte, maxDepth int) (any, bool) {
	if !utf8.Valid(data) || !scalarJSONEscapes(data) {
		return nil, false
	}
	depth := 0
	quoted := false
	escaped := false
	for _, b := range data {
		if quoted {
			if escaped {
				escaped = false
			} else if b == '\\' {
				escaped = true
			} else if b == '"' {
				quoted = false
			}
			continue
		}
		if b == '"' {
			quoted = true
		} else if b == '{' || b == '[' {
			depth++
			if depth > maxDepth {
				return nil, false
			}
		} else if b == '}' || b == ']' {
			depth--
		}
	}
	var value any
	if json.Unmarshal(data, &value) != nil {
		return nil, false
	}
	return value, true
}

// encoding/json replaces unpaired UTF-16 escapes. Reject them before decoding
// so the transport never silently changes request or provider strings/keys.
func scalarJSONEscapes(data []byte) bool {
	quoted := false
	for i := 0; i < len(data); i++ {
		b := data[i]
		if !quoted {
			if b == '"' {
				quoted = true
			}
			continue
		}
		if b == '"' {
			quoted = false
			continue
		}
		if b != '\\' {
			continue
		}
		i++
		if i >= len(data) {
			return false
		}
		if data[i] != 'u' {
			continue
		}
		if i+4 >= len(data) {
			return false
		}
		unit, err := strconv.ParseUint(string(data[i+1:i+5]), 16, 16)
		if err != nil {
			return false
		}
		i += 4
		if unit >= 0xdc00 && unit <= 0xdfff {
			return false
		}
		if unit >= 0xd800 && unit <= 0xdbff {
			if i+6 >= len(data) || data[i+1] != '\\' || data[i+2] != 'u' {
				return false
			}
			low, err := strconv.ParseUint(string(data[i+3:i+7]), 16, 16)
			if err != nil || low < 0xdc00 || low > 0xdfff {
				return false
			}
			i += 6
		}
	}
	return true
}
func transportObject(value any) (map[string]any, bool) { m, ok := value.(map[string]any); return m, ok }
func exactTransportKeys(m map[string]any, required []string, optional ...string) bool {
	for _, key := range required {
		if _, ok := m[key]; !ok {
			return false
		}
	}
	for key := range m {
		if !contains(required, key) && !contains(optional, key) {
			return false
		}
	}
	return true
}
func encodeHistoryMessages(selection Selection, messages []any) ([]any, bool, error) {
	type pendingCall struct{ id, name string }
	encoded := make([]any, 0, len(messages))
	var pending []pendingCall
	cursor := 0
	hasHistory := false
	for _, raw := range messages {
		m, ok := transportObject(raw)
		if !ok {
			return nil, false, ErrInvalidRequest
		}
		role, roleOK := m["role"].(string)
		content, contentOK := m["content"].(string)
		if !roleOK || !contentOK {
			return nil, false, ErrInvalidRequest
		}
		if role == "tool" {
			if !exactTransportKeys(m, []string{"role", "content", "toolCallId"}) || cursor >= len(pending) || m["toolCallId"] != pending[cursor].id {
				return nil, false, ErrInvalidRequest
			}
			call := pending[cursor]
			if selection.Adapter == "ollama" {
				encoded = append(encoded, map[string]any{"role": "tool", "tool_name": call.name, "content": content})
			} else {
				encoded = append(encoded, map[string]any{"role": "tool", "tool_call_id": call.id, "content": content})
			}
			cursor++
			if cursor == len(pending) {
				pending = nil
				cursor = 0
			}
			continue
		}
		if len(pending) > 0 || !contains([]string{"system", "user", "assistant"}, role) {
			return nil, false, ErrInvalidRequest
		}
		callsValue, hasCalls := m["toolCalls"]
		if role != "assistant" || !hasCalls {
			if !exactTransportKeys(m, []string{"role", "content"}) {
				return nil, false, ErrInvalidRequest
			}
			encoded = append(encoded, m)
			continue
		}
		if !exactTransportKeys(m, []string{"role", "content", "toolCalls"}) {
			return nil, false, ErrInvalidRequest
		}
		calls, ok := callsValue.([]any)
		if !ok || len(calls) == 0 || len(calls) > 32 {
			return nil, false, ErrInvalidRequest
		}
		ids := map[string]bool{}
		providerCalls := make([]any, 0, len(calls))
		for index, rawCall := range calls {
			call, ok := transportObject(rawCall)
			if !ok || !exactTransportKeys(call, []string{"id", "name", "arguments"}) {
				return nil, false, ErrInvalidRequest
			}
			id, idOK := call["id"].(string)
			name, nameOK := call["name"].(string)
			args, argsOK := transportObject(call["arguments"])
			if !idOK || id == "" || utf8.RuneCountInString(id) > 128 || ids[id] || !nameOK || !toolName.MatchString(name) || !argsOK {
				return nil, false, ErrInvalidRequest
			}
			ids[id] = true
			pending = append(pending, pendingCall{id: id, name: name})
			if selection.Adapter == "ollama" {
				providerCalls = append(providerCalls, map[string]any{"type": "function", "function": map[string]any{"index": index, "name": name, "arguments": args}})
			} else {
				var buffer bytes.Buffer
				encoder := json.NewEncoder(&buffer)
				encoder.SetEscapeHTML(false)
				if encoder.Encode(args) != nil {
					return nil, false, ErrInvalidRequest
				}
				providerCalls = append(providerCalls, map[string]any{"id": id, "type": "function", "function": map[string]any{"name": name, "arguments": string(bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'}))}})
			}
		}
		hasHistory = true
		encoded = append(encoded, map[string]any{"role": "assistant", "content": content, "tool_calls": providerCalls})
	}
	if len(pending) > 0 {
		return nil, false, ErrInvalidRequest
	}
	return encoded, hasHistory, nil
}
func encodeTransport(selection Selection, data []byte) ([]byte, map[string]bool, bool, error) {
	if len(data) > transportLimit {
		return nil, nil, false, ErrInvalidRequest
	}
	raw, ok := boundedJSON(data, 64)
	if !ok {
		return nil, nil, false, ErrInvalidRequest
	}
	request, ok := transportObject(raw)
	if !ok || !exactTransportKeys(request, []string{"messages"}, "tools", "responseSchema") {
		return nil, nil, false, ErrInvalidRequest
	}
	messages, ok := request["messages"].([]any)
	if !ok || len(messages) < 1 || len(messages) > 128 {
		return nil, nil, false, ErrInvalidRequest
	}
	encodedMessages, hasHistory, err := encodeHistoryMessages(selection, messages)
	if err != nil {
		return nil, nil, false, err
	}
	tools := []any{}
	if v, present := request["tools"]; present {
		tools, ok = v.([]any)
		if !ok || len(tools) > 32 {
			return nil, nil, false, ErrInvalidRequest
		}
	}
	names := map[string]bool{}
	encodedTools := []any{}
	for _, raw := range tools {
		tool, ok := transportObject(raw)
		if !ok || !exactTransportKeys(tool, []string{"name", "description", "parameters"}) {
			return nil, nil, false, ErrInvalidRequest
		}
		name, ok := tool["name"].(string)
		if !ok || !toolName.MatchString(name) || names[name] {
			return nil, nil, false, ErrInvalidRequest
		}
		if _, ok = tool["description"].(string); !ok {
			return nil, nil, false, ErrInvalidRequest
		}
		schema, ok := transportObject(tool["parameters"])
		if !ok || schema["type"] != "object" {
			return nil, nil, false, ErrInvalidRequest
		}
		names[name] = true
		encodedTools = append(encodedTools, map[string]any{"type": "function", "function": tool})
	}
	schema, structured := request["responseSchema"]
	if structured {
		m, ok := transportObject(schema)
		if !ok || m["type"] != "object" || len(tools) > 0 {
			return nil, nil, false, ErrInvalidRequest
		}
	}
	if ((len(tools) > 0 || hasHistory) && !contains(selection.Capabilities, "tools")) || (structured && !contains(selection.Capabilities, "structured-output")) {
		return nil, nil, false, ErrUnsupportedCapability
	}
	body := map[string]any{"model": selection.Model, "messages": encodedMessages, "stream": false}
	switch selection.Adapter {
	case "openai-compatible":
		body["n"] = 1
		body["max_tokens"] = selection.MaxOutputTokens
	case "ollama":
		body["options"] = map[string]any{"num_predict": selection.MaxOutputTokens, "num_ctx": selection.ContextWindowTokens}
	default:
		return nil, nil, false, ErrInvalidRequest
	}
	if len(tools) > 0 {
		body["tools"] = encodedTools
	}
	if structured {
		if selection.Adapter == "ollama" {
			body["format"] = schema
		} else {
			body["response_format"] = map[string]any{"type": "json_schema", "json_schema": map[string]any{"name": "output", "strict": true, "schema": schema}}
		}
	}
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	err = encoder.Encode(body)
	encoded := bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'})
	if err != nil || len(encoded) > transportLimit {
		return nil, nil, false, ErrInvalidRequest
	}
	if _, ok = boundedJSON(encoded, 70); !ok {
		return nil, nil, false, ErrInvalidRequest
	}
	return encoded, names, structured, nil
}
func transportTokens(m map[string]any, key string) (*int64, bool) {
	value, present := m[key]
	if !present {
		return nil, true
	}
	number, ok := value.(float64)
	if !ok || math.IsNaN(number) || math.IsInf(number, 0) || number < 0 || number > 9007199254740991 || number != math.Trunc(number) {
		return nil, false
	}
	result := int64(number)
	return &result, true
}
func normalizeTransport(selection Selection, data []byte, names map[string]bool, structured bool) (InferenceResult, error) {
	invalid := func() (InferenceResult, error) { return InferenceResult{}, ErrInvalidProviderResponse }
	raw, ok := boundedJSON(data, 70)
	if !ok {
		return invalid()
	}
	response, ok := transportObject(raw)
	if !ok {
		return invalid()
	}
	openai := selection.Adapter == "openai-compatible"
	var message map[string]any
	finish := ""
	usage := map[string]any{}
	inputKey := "prompt_tokens"
	outputKey := "completion_tokens"
	if openai {
		choices, ok := response["choices"].([]any)
		if !ok || len(choices) != 1 {
			return invalid()
		}
		choice, ok := transportObject(choices[0])
		if !ok || choice["index"] != float64(0) {
			return invalid()
		}
		reason, ok := choice["finish_reason"].(string)
		if !ok {
			return invalid()
		}
		finish = map[string]string{"stop": "stop", "length": "length", "tool_calls": "tool-calls", "content_filter": "content-filter"}[reason]
		if finish == "" {
			return invalid()
		}
		message, ok = transportObject(choice["message"])
		if !ok {
			return invalid()
		}
		if value := response["usage"]; value != nil {
			usage, ok = transportObject(value)
			if !ok {
				return invalid()
			}
		}
	} else {
		if response["done"] != true {
			return invalid()
		}
		finish, ok = response["done_reason"].(string)
		if !ok || (finish != "stop" && finish != "length") {
			return invalid()
		}
		message, ok = transportObject(response["message"])
		if !ok {
			return invalid()
		}
		usage = response
		inputKey = "prompt_eval_count"
		outputKey = "eval_count"
	}
	if message["role"] != "assistant" {
		return invalid()
	}
	input, ok := transportTokens(usage, inputKey)
	if !ok {
		return invalid()
	}
	output, ok := transportTokens(usage, outputKey)
	if !ok {
		return invalid()
	}
	calls := []any{}
	if value := message["tool_calls"]; value != nil {
		calls, ok = value.([]any)
		if !ok || len(calls) > 32 {
			return invalid()
		}
	}
	proposals := make([]ToolProposal, 0, len(calls))
	ids := map[string]bool{}
	for i, value := range calls {
		call, ok := transportObject(value)
		if !ok {
			return invalid()
		}
		typ, present := call["type"]
		if (openai || present) && typ != "function" {
			return invalid()
		}
		fn, ok := transportObject(call["function"])
		if !ok {
			return invalid()
		}
		name, ok := fn["name"].(string)
		if !ok || !names[name] {
			return invalid()
		}
		id := "ollama-" + strconvTransport(i)
		if openai {
			id, ok = call["id"].(string)
			if !ok || id == "" || utf8.RuneCountInString(id) > 128 || ids[id] {
				return invalid()
			}
		}
		ids[id] = true
		args := fn["arguments"]
		if openai {
			text, ok := args.(string)
			if !ok {
				return invalid()
			}
			args, ok = boundedJSON([]byte(text), 64)
			if !ok {
				return invalid()
			}
		} else {
			encoded, err := json.Marshal(args)
			if err != nil {
				return invalid()
			}
			if _, ok = boundedJSON(encoded, 64); !ok {
				return invalid()
			}
		}
		arguments, ok := transportObject(args)
		if !ok {
			return invalid()
		}
		proposals = append(proposals, ToolProposal{ID: id, Name: name, Arguments: arguments})
	}
	if len(calls) > 0 {
		if (openai && finish != "tool-calls") || (!openai && finish != "stop") {
			return invalid()
		}
		finish = "tool-calls"
	}
	text, textOK := message["content"].(string)
	content, present := message["content"]
	if !textOK && (!openai || !present || content != nil || len(calls) == 0) {
		return invalid()
	}
	if len(calls) == 0 && (text == "" || finish == "tool-calls") {
		return invalid()
	}
	if structured {
		v, ok := boundedJSON([]byte(text), 64)
		if !ok || finish != "stop" {
			return invalid()
		}
		if _, ok = transportObject(v); !ok {
			return invalid()
		}
	}
	return InferenceResult{Text: text, ToolCalls: proposals, FinishReason: finish, Usage: InferenceUsage{InputTokens: input, OutputTokens: output}}, nil
}
func strconvTransport(i int) string { return strconv.Itoa(i) }
func transportIOError(parent, request context.Context) error {
	if parent.Err() != nil {
		return ErrCancelled
	}
	if request.Err() != nil {
		return ErrTimeout
	}
	return ErrProviderUnavailable
}

// Infer receives only a server-created routing snapshot and JSON request. It
// never executes tools or claims JSON Schema validation of a provider reply.
func (t *Transport) Infer(ctx context.Context, snapshot Selection, request []byte) (InferenceResult, error) {
	if ctx.Err() != nil {
		return InferenceResult{}, ErrCancelled
	}
	selection := cloneSelection(snapshot)
	encoded, names, structured, err := encodeTransport(selection, request)
	if err != nil {
		return InferenceResult{}, err
	}
	if !validBaseURL(selection.BaseURL) {
		return InferenceResult{}, ErrInvalidRequest
	}
	credential := ""
	if selection.APIKeyEnv != nil {
		if t.resolver == nil {
			return InferenceResult{}, ErrMissingCredential
		}
		credential, err = t.resolver(*selection.APIKeyEnv)
		if err != nil || credential == "" {
			return InferenceResult{}, ErrMissingCredential
		}
		for _, b := range []byte(credential) {
			if b < 0x21 || b > 0x7e {
				return InferenceResult{}, ErrMissingCredential
			}
		}
	}
	path := "/chat/completions"
	if selection.Adapter == "ollama" {
		path = "/api/chat"
	}
	requestContext, cancel := context.WithTimeout(ctx, t.timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(requestContext, http.MethodPost, strings.TrimRight(selection.BaseURL, "/")+path, bytes.NewReader(encoded))
	if err != nil {
		return InferenceResult{}, ErrInvalidRequest
	}
	// NewRequest adds GetBody for bytes.Reader, enabling a transparent retry
	// after a failed write on a reused connection. A single attempt is required.
	req.GetBody = nil
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept-Encoding", "identity")
	if credential != "" {
		req.Header.Set("Authorization", "Bearer "+credential)
	}
	response, err := t.client.Do(req)
	if err != nil {
		return InferenceResult{}, transportIOError(ctx, requestContext)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return InferenceResult{}, ErrProviderRejected
	}
	encoding, encodingPresent := response.Header["Content-Encoding"]
	if encodingPresent && (len(encoding) != 1 || strings.ToLower(strings.Trim(encoding[0], " \t\n\v\f\r")) != "identity") {
		return InferenceResult{}, ErrInvalidProviderResponse
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, transportLimit+1))
	if err != nil {
		return InferenceResult{}, transportIOError(ctx, requestContext)
	}
	if len(body) > transportLimit {
		return InferenceResult{}, ErrResponseTooLarge
	}
	return normalizeTransport(selection, body, names, structured)
}
