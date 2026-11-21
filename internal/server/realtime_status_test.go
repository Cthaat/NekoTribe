package server

import (
	"encoding/json"
	"os"
	"testing"
)

func TestSharedLocalPresenceStatusValidation(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/local-presence.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		StatusCases []struct {
			ID     string          `json:"id"`
			Remote json.RawMessage `json:"remote_events"`
			Local  json.RawMessage `json:"local_presence"`
			Valid  bool            `json:"valid"`
		} `json:"statusCases"`
	}
	if json.Unmarshal(raw, &fixture) != nil || len(fixture.StatusCases) == 0 {
		t.Fatal("missing shared status cases")
	}
	stamp := 1234.0
	for _, test := range fixture.StatusCases {
		t.Run(test.ID, func(t *testing.T) {
			data := map[string]json.RawMessage{"code": json.RawMessage(`"realtime_status"`), "user_id": json.RawMessage(`42`), "server_id": json.RawMessage(`"instance"`), "local_presence": test.Local, "remote_events": test.Remote}
			if validRealtimeStatus("system_notification", data, &stamp, 42) != test.Valid {
				t.Fatal("incorrect status validation")
			}
			body, err := json.Marshal(map[string]interface{}{"type": "system_notification", "data": data, "timestamp": stamp})
			if err != nil {
				t.Fatal(err)
			}
			if socketEventMatchesChannel("ws:user:42", "ws:user:42", body) || socketEventMatchesChannel("ws:presence", "ws:user:42", body) {
				t.Fatal("broker input can forge status")
			}
			if validRealtimeStatus("system_notification", data, &stamp, 9) {
				t.Fatal("status crossed account")
			}
		})
	}
	data := map[string]json.RawMessage{"code": json.RawMessage(`"realtime_status"`), "user_id": json.RawMessage(`42`), "server_id": json.RawMessage(`"instance"`), "local_presence": json.RawMessage(`true`), "remote_events": json.RawMessage(`"connected"`)}
	for _, stamp := range []float64{-1, 0.5, 9007199254740992} {
		if validRealtimeStatus("system_notification", data, &stamp, 42) {
			t.Fatal("invalid timestamp", stamp)
		}
	}
	if validRealtimeStatus("system_notification", data, nil, 42) || validRealtimeStatus("notification_created", data, &stamp, 42) {
		t.Fatal("invalid status envelope")
	}
}

func TestSharedLocalPresenceRemoteFrames(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/local-presence.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		RemoteCases []struct {
			ID    string          `json:"id"`
			Frame json.RawMessage `json:"frame"`
			Valid bool            `json:"valid"`
		} `json:"remoteCases"`
	}
	if json.Unmarshal(raw, &fixture) != nil || len(fixture.RemoteCases) == 0 {
		t.Fatal("missing remote cases")
	}
	for _, test := range fixture.RemoteCases {
		t.Run(test.ID, func(t *testing.T) {
			if socketEventMatchesChannel("ws:presence", "ws:user:42", test.Frame) != test.Valid {
				t.Fatal("incorrect remote presence validation")
			}
		})
	}
}
