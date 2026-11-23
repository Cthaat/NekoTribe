package server

import (
	"encoding/json"
	"regexp"
	"unicode/utf8"
)

var webRTCClientID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

const (
	webRTCInvite      = "call_invite"
	webRTCAccept      = "call_accept"
	webRTCReject      = "call_reject"
	webRTCCancel      = "call_cancel"
	webRTCOffer       = "call_sdp_offer"
	webRTCAnswer      = "call_sdp_answer"
	webRTCIce         = "call_ice"
	webRTCHangup      = "call_hangup"
	webRTCTimeout     = "call_timeout"
	webRTCBusy        = "call_busy"
	webRTCUnavailable = "call_unavailable"
)

type webRTCIceCandidate struct {
	Candidate string  `json:"candidate"`
	Mid       *string `json:"sdp_mid,omitempty"`
	LineIndex *uint16 `json:"sdp_mline_index,omitempty"`
}

type webRTCSignal struct {
	sdp        string
	candidates []webRTCIceCandidate
}

type webRTCInput struct {
	id, client, mode string
	conversation     int64
	signal           webRTCSignal
}

type webRTCIdentity struct {
	id, mode, callerClient, calleeClient string
	conversation, caller, callee         int64
}

type webRTCEvent struct {
	call   webRTCIdentity
	signal webRTCSignal
}

func webRTCAction(kind string) string {
	switch kind {
	case webRTCInvite:
		return "invite"
	case webRTCAccept:
		return "accept"
	case webRTCReject:
		return "reject"
	case webRTCCancel:
		return "cancel"
	case webRTCOffer:
		return "offer"
	case webRTCAnswer:
		return "answer"
	case webRTCIce:
		return "ice"
	case webRTCHangup:
		return "hangup"
	}
	return ""
}

func isWebRTCBrokerEvent(kind string) bool {
	return webRTCAction(kind) != "" || kind == webRTCTimeout
}

func isWebRTCSignal(kind string) bool {
	return kind == webRTCOffer || kind == webRTCAnswer || kind == webRTCIce
}

func validWebRTCMode(mode string) bool {
	return mode == "voice" || mode == "video"
}

func webRTCString(raw json.RawMessage) (string, bool) {
	var value *string
	if json.Unmarshal(raw, &value) != nil || value == nil {
		return "", false
	}
	return *value, true
}

func decodeWebRTCInput(raw []byte, kind string) (webRTCInput, bool) {
	var out webRTCInput
	if !utf8.Valid(raw) || !validJSONSurrogates(raw) {
		return out, false
	}
	data := strictSocketSignalData(raw, "type", "data")
	out.id, _ = webRTCString(data["call_id"])
	out.client, _ = webRTCString(data["client_id"])
	out.conversation = numericChatSocketID(data["conversation_id"])
	if !webRTCClientID.MatchString(out.id) || !webRTCClientID.MatchString(out.client) || out.conversation == 0 {
		return out, false
	}
	switch {
	case kind == webRTCInvite:
		out.mode, _ = webRTCString(data["mode"])
		return out, len(data) == 4 && validWebRTCMode(out.mode)
	case isWebRTCSignal(kind):
		if len(data) != 4 {
			return out, false
		}
		var ok bool
		out.signal, ok = decodeWebRTCSignal(kind, data)
		return out, ok
	default:
		return out, webRTCAction(kind) != "" && len(data) == 3
	}
}

func decodeWebRTCBrokerFrame(raw []byte, kind string) (webRTCEvent, bool) {
	var out webRTCEvent
	if !isWebRTCBrokerEvent(kind) || !utf8.Valid(raw) || !validJSONSurrogates(raw) {
		return out, false
	}
	data := strictSocketSignalData(raw, "type", "timestamp", "data")
	call := &out.call
	call.id, _ = webRTCString(data["call_id"])
	call.mode, _ = webRTCString(data["mode"])
	call.callerClient, _ = webRTCString(data["caller_client_id"])
	call.conversation = numericChatSocketID(data["conversation_id"])
	call.caller = numericChatSocketID(data["caller_id"])
	call.callee = numericChatSocketID(data["callee_id"])
	if !call.valid() {
		return out, false
	}
	fields := 6
	if value, present := data["callee_client_id"]; present {
		call.calleeClient, _ = webRTCString(value)
		if !webRTCClientID.MatchString(call.calleeClient) {
			return out, false
		}
		fields++
	}
	if kind == webRTCAccept || kind == webRTCHangup || isWebRTCSignal(kind) {
		if call.calleeClient == "" {
			return out, false
		}
	}
	if value, present := data["server_id"]; present {
		serverID, _ := webRTCString(value)
		if serverID == "" {
			return out, false
		}
		fields++
	}
	if isWebRTCSignal(kind) {
		var ok bool
		out.signal, ok = decodeWebRTCSignal(kind, data)
		if !ok {
			return out, false
		}
		fields++
	}
	return out, len(data) == fields
}

func decodeWebRTCSignal(kind string, data map[string]json.RawMessage) (webRTCSignal, bool) {
	var signal webRTCSignal
	if kind == webRTCOffer || kind == webRTCAnswer {
		signal.sdp, _ = webRTCString(data["sdp"])
		return signal, signal.sdp != "" && len(signal.sdp) <= webRTCCallContract.MaxSDPBytes
	}
	var items []json.RawMessage
	if json.Unmarshal(data["candidates"], &items) != nil || len(items) == 0 || len(items) > webRTCCallContract.MaxICECandidates {
		return signal, false
	}
	for _, raw := range items {
		item, ok := decodeWebRTCIceCandidate(raw)
		if !ok {
			return webRTCSignal{}, false
		}
		signal.candidates = append(signal.candidates, item)
	}
	return signal, true
}

func decodeWebRTCIceCandidate(raw json.RawMessage) (webRTCIceCandidate, bool) {
	var candidate webRTCIceCandidate
	var data map[string]json.RawMessage
	if json.Unmarshal(raw, &data) != nil || hasTooManyJSONMembers(raw, len(data)) {
		return candidate, false
	}
	candidate.Candidate, _ = webRTCString(data["candidate"])
	if candidate.Candidate == "" || len(candidate.Candidate) > webRTCCallContract.MaxICEBytes {
		return candidate, false
	}
	fields := 1
	if raw, present := data["sdp_mid"]; present {
		mid, valid := webRTCString(raw)
		if !valid || utf8.RuneCountInString(mid) > 128 {
			return candidate, false
		}
		candidate.Mid = &mid
		fields++
	}
	if raw, present := data["sdp_mline_index"]; present {
		if json.Unmarshal(raw, &candidate.LineIndex) != nil || candidate.LineIndex == nil {
			return candidate, false
		}
		fields++
	}
	return candidate, len(data) == fields
}

func (call webRTCIdentity) valid() bool {
	return webRTCClientID.MatchString(call.id) && webRTCClientID.MatchString(call.callerClient) && validWebRTCMode(call.mode) &&
		call.conversation > 0 && call.conversation <= maxSocketID && call.caller > 0 && call.caller <= maxSocketID &&
		call.callee > 0 && call.callee <= maxSocketID && call.caller != call.callee
}

func (event webRTCEvent) payload(serverID string) map[string]any {
	call := event.call
	data := map[string]any{"call_id": call.id, "conversation_id": call.conversation, "caller_id": call.caller,
		"callee_id": call.callee, "mode": call.mode, "caller_client_id": call.callerClient}
	if call.calleeClient != "" {
		data["callee_client_id"] = call.calleeClient
	}
	if serverID != "" {
		data["server_id"] = serverID
	}
	if event.signal.sdp != "" {
		data["sdp"] = event.signal.sdp
	}
	if event.signal.candidates != nil {
		data["candidates"] = event.signal.candidates
	}
	return data
}
