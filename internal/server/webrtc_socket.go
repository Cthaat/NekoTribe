package server

import (
	"context"
	"time"
)

type webRTCPeerAccess interface {
	DirectTypingPeer(context.Context, int64, int64) (int64, error)
}

type webRTCCallTransport interface {
	webRTCCallState() webRTCStateStore
	publishWebRTCCall(context.Context, string, webRTCEvent, ...int64) error
}

type webRTCSocket struct {
	actor      int64
	connection string
	access     webRTCPeerAccess
	transport  webRTCCallTransport
	state      webRTCStateStore
	clock      func() time.Time
	bound      webRTCTransition
	ring       *time.Timer
}

func newWebRTCSocket(actor int64, connection string, repository SessionRepository, config RefreshConfig) *webRTCSocket {
	socket := &webRTCSocket{actor: actor, connection: connection, clock: config.clock}
	socket.access, _ = repository.(webRTCPeerAccess)
	if transport, ok := config.DirectEvents.(webRTCCallTransport); ok {
		socket.transport, socket.state = transport, transport.webRTCCallState()
	}
	return socket
}

func (socket *webRTCSocket) currentPeer(ctx context.Context, conversation int64) int64 {
	if socket.access == nil {
		return 0
	}
	check, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	peer, err := socket.access.DirectTypingPeer(check, socket.actor, conversation)
	if err != nil || peer <= 0 || peer > maxSocketID || peer == socket.actor {
		return 0
	}
	return peer
}

func (socket *webRTCSocket) request(ctx context.Context, kind string, raw []byte) (response string, data map[string]any) {
	invalid := func() (string, map[string]any) {
		return "error", map[string]any{"message": "通话请求无效"}
	}
	input, valid := decodeWebRTCInput(raw, kind)
	if !valid {
		return invalid()
	}
	peer := socket.currentPeer(ctx, input.conversation)
	if peer == 0 {
		return invalid()
	}
	step := webRTCTransition{
		action: webRTCAction(kind), id: input.id, client: input.client, connection: socket.connection, mode: input.mode,
		conversation: input.conversation, actor: socket.actor, peer: peer, now: socket.clock().UnixMilli(),
	}
	unavailable := func() (string, map[string]any) {
		if kind != webRTCInvite {
			return invalid()
		}
		return webRTCUnavailable, (webRTCEvent{call: step.inviteIdentity()}).payload("")
	}
	if socket.state == nil {
		return unavailable()
	}
	status, call, err := socket.state.apply(ctx, step)
	if err != nil {
		return unavailable()
	}
	switch status {
	case "busy":
		if kind == webRTCInvite {
			return webRTCBusy, (webRTCEvent{call: step.inviteIdentity()}).payload("")
		}
		return invalid()
	case "timeout":
		socket.clearBound(call.id)
		socket.publishControl(ctx, webRTCTimeout, call)
		return "", nil
	case "ok":
	default:
		return invalid()
	}

	if isWebRTCSignal(kind) {
		if err := socket.transport.publishWebRTCCall(ctx, kind, webRTCEvent{call.webRTCIdentity, input.signal}, peer); err != nil {
			return unavailable()
		}
		return "", nil
	}

	switch kind {
	case webRTCInvite, webRTCAccept:
		socket.stopRing()
		socket.bound = step
		if kind == webRTCInvite {
			milliseconds := max(0, call.deadline-socket.clock().UnixMilli())
			socket.ring = time.NewTimer(time.Duration(milliseconds) * time.Millisecond)
		}
	case webRTCReject, webRTCCancel, webRTCHangup:
		socket.clearBound(call.id)
	}
	if socket.publishControl(ctx, kind, call) != nil {
		if kind == webRTCInvite || kind == webRTCAccept {
			socket.disconnect(ctx)
		}
		return unavailable()
	}
	return "", nil
}

func (socket *webRTCSocket) publishControl(ctx context.Context, event string, call webRTCCall) error {
	return socket.transport.publishWebRTCCall(ctx, event, webRTCEvent{call: call.webRTCIdentity}, call.caller, call.callee)
}

func (socket *webRTCSocket) ringDeadline() <-chan time.Time {
	if socket.ring == nil {
		return nil
	}
	return socket.ring.C
}

func (socket *webRTCSocket) stopRing() {
	if socket.ring != nil {
		socket.ring.Stop()
		socket.ring = nil
	}
}

func (socket *webRTCSocket) clearBound(callID string) {
	if socket.bound.id == callID {
		socket.bound = webRTCTransition{}
		socket.stopRing()
	}
}

func (socket *webRTCSocket) expire(ctx context.Context) {
	socket.stopRing()
	if socket.bound.id == "" {
		return
	}
	step := socket.bound
	step.action, step.now = "expire", socket.clock().UnixMilli()
	status, call, err := socket.state.apply(ctx, step)
	if err == nil && status == "timeout" {
		socket.clearBound(call.id)
		socket.publishControl(ctx, webRTCTimeout, call)
	}
}

func (socket *webRTCSocket) disconnect(ctx context.Context) {
	socket.stopRing()
	if socket.bound.id == "" {
		return
	}
	step := socket.bound
	socket.clearBound(step.id)
	step.action, step.now = "disconnect", socket.clock().UnixMilli()
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer cancel()
	status, call, err := socket.state.apply(cleanup, step)
	if err != nil {
		return
	}
	switch {
	case status == "timeout":
		socket.publishControl(cleanup, webRTCTimeout, call)
	case status == "ok" && call.stage == "ringing":
		socket.publishControl(cleanup, webRTCCancel, call)
	case status == "ok":
		socket.publishControl(cleanup, webRTCHangup, call)
	}
}

func (socket *webRTCSocket) canDeliver(ctx context.Context, kind string, event webRTCEvent) bool {
	call := event.call
	peer := call.peerOf(socket.actor)
	if peer == 0 || socket.currentPeer(ctx, call.conversation) != peer {
		return false
	}
	switch kind {
	case webRTCReject, webRTCCancel, webRTCTimeout, webRTCHangup:
		socket.clearBound(call.id)
		return true
	}
	if socket.state == nil {
		return false
	}
	current, found, err := socket.state.find(ctx, call.id)
	if err != nil || !found || current.webRTCIdentity != call || current.deadline <= socket.clock().UnixMilli() {
		return false
	}
	switch kind {
	case webRTCInvite:
		return current.stage == "ringing"
	case webRTCAccept:
		if current.stage == "ringing" {
			return false
		}
		if socket.bound.id == call.id {
			socket.stopRing()
		}
		return true
	}
	connection, client := current.socketOf(socket.actor)
	if current.stage == "ringing" || socket.bound.id != call.id || socket.bound.client != client || socket.connection != connection {
		return false
	}
	switch kind {
	case webRTCOffer:
		return socket.actor == call.callee && (current.stage == "await_answer" || current.stage == "connected")
	case webRTCAnswer:
		return socket.actor == call.caller && current.stage == "connected"
	case webRTCIce:
		return true
	}
	return false
}
