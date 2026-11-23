package server

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/redis/go-redis/v9"
)

var errWebRTCState = errors.New("WebRTC state unavailable")

var webRTCStateScript = func() string {
	var script struct{ Lines []string }
	if json.Unmarshal(contracts.WebRTCCallState, &script) != nil || len(script.Lines) == 0 {
		panic("invalid WebRTC call state contract")
	}
	return strings.Join(script.Lines, "\n")
}()

type webRTCCall struct {
	webRTCIdentity
	callerConnection, calleeConnection string
	stage                              string
	deadline                           int64
}

type webRTCTransition struct {
	action, id, client, connection, mode string
	conversation, actor, peer, now       int64
}

func (step webRTCTransition) inviteIdentity() webRTCIdentity {
	return webRTCIdentity{
		id: step.id, conversation: step.conversation, caller: step.actor, callee: step.peer,
		mode: step.mode, callerClient: step.client,
	}
}

type webRTCStateStore interface {
	apply(context.Context, webRTCTransition) (string, webRTCCall, error)
	find(context.Context, string) (webRTCCall, bool, error)
}

type webRTCRedisClient interface {
	Eval(context.Context, string, []string, ...any) *redis.Cmd
	Get(context.Context, string) *redis.StringCmd
}

type webRTCRedisStore struct {
	client webRTCRedisClient
}

func (store webRTCRedisStore) apply(ctx context.Context, step webRTCTransition) (string, webRTCCall, error) {
	prefix := webRTCCallContract.RedisKeyPrefix
	actor := strconv.FormatInt(step.actor, 10)
	peer := strconv.FormatInt(step.peer, 10)
	keys := []string{prefix + "call:" + step.id, prefix + "user:" + actor, prefix + "user:" + peer}
	request, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	raw, err := store.client.Eval(request, webRTCStateScript, keys, step.action, step.id, strconv.FormatInt(step.conversation, 10),
		actor, peer, step.client, step.connection, step.mode, step.now, webRTCCallContract.RingMS, webRTCCallContract.ActiveMS).Result()
	values, ok := raw.([]any)
	if err != nil || !ok || len(values) != 2 {
		return "", webRTCCall{}, errWebRTCState
	}
	status, validStatus := values[0].(string)
	entry, validEntry := values[1].(string)
	if !validStatus || !validEntry {
		return "", webRTCCall{}, errWebRTCState
	}
	switch status {
	case "busy", "invalid_state", "not_found", "forbidden":
		if entry == "" {
			return status, webRTCCall{}, nil
		}
	case "ok", "timeout":
		call, ok := decodeWebRTCCallState(entry)
		if ok && call.id == step.id && call.conversation == step.conversation && call.peerOf(step.actor) == step.peer {
			return status, call, nil
		}
	}
	return "", webRTCCall{}, errWebRTCState
}

func (store webRTCRedisStore) find(ctx context.Context, id string) (webRTCCall, bool, error) {
	request, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	entry, err := store.client.Get(request, webRTCCallContract.RedisKeyPrefix+"call:"+id).Result()
	if errors.Is(err, redis.Nil) {
		return webRTCCall{}, false, nil
	}
	call, ok := decodeWebRTCCallState(entry)
	if err != nil || !ok || call.id != id {
		return webRTCCall{}, false, errWebRTCState
	}
	return call, true, nil
}

func decodeWebRTCCallState(entry string) (webRTCCall, bool) {
	var row struct {
		ID               string `json:"call_id"`
		Conversation     string `json:"conversation_id"`
		Mode             string `json:"mode"`
		Caller           string `json:"caller_id"`
		Callee           string `json:"callee_id"`
		CallerClient     string `json:"caller_client_id"`
		CalleeClient     string `json:"callee_client_id"`
		CallerConnection string `json:"caller_connection"`
		CalleeConnection string `json:"callee_connection"`
		Stage            string `json:"stage"`
		Deadline         int64  `json:"deadline"`
	}
	if json.Unmarshal([]byte(entry), &row) != nil {
		return webRTCCall{}, false
	}
	conversation, err := strconv.ParseInt(row.Conversation, 10, 64)
	caller, callerErr := strconv.ParseInt(row.Caller, 10, 64)
	callee, calleeErr := strconv.ParseInt(row.Callee, 10, 64)
	call := webRTCCall{
		webRTCIdentity: webRTCIdentity{
			id: row.ID, mode: row.Mode, callerClient: row.CallerClient, calleeClient: row.CalleeClient,
			conversation: conversation, caller: caller, callee: callee,
		},
		callerConnection: row.CallerConnection, calleeConnection: row.CalleeConnection, stage: row.Stage, deadline: row.Deadline,
	}
	if err != nil || callerErr != nil || calleeErr != nil || !call.valid() || call.callerConnection == "" || call.deadline <= 0 {
		return webRTCCall{}, false
	}
	switch call.stage {
	case "ringing":
		return call, call.calleeClient == "" && call.calleeConnection == ""
	case "await_offer", "await_answer", "connected":
		return call, webRTCClientID.MatchString(call.calleeClient) && call.calleeConnection != ""
	default:
		return webRTCCall{}, false
	}
}

func (call webRTCIdentity) peerOf(actor int64) int64 {
	switch actor {
	case call.caller:
		return call.callee
	case call.callee:
		return call.caller
	default:
		return 0
	}
}

func (call webRTCCall) socketOf(actor int64) (connection, client string) {
	switch actor {
	case call.caller:
		return call.callerConnection, call.callerClient
	case call.callee:
		return call.calleeConnection, call.calleeClient
	default:
		return "", ""
	}
}
