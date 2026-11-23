package server

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDirectExtrasSendParsesPrivateAttachmentOnlyAndReply(t *testing.T) {
	value, err := parseDirectSend([]byte(`{"content":"  ","media_ids":[9007199254740991,88],"reply_to_message_id":77}`))
	if err != nil || value.content != "" || len(value.media) != 2 || value.media[0] != maxSocketID || value.reply == nil || *value.reply != 77 {
		t.Fatal(value, err)
	}
	for _, raw := range []string{
		`{"content":"  ","reply_to_message_id":77}`,
		`{"media_ids":[1,1]}`,
		`{"media_ids":[9007199254740992]}`,
		`{"media_ids":["1"]}`,
		`{"content":"text","reply_to_message_id":2.5}`,
		`{"content":"text","media_ids":null}`,
		`{"content":"text","sender_id":99}`,
	} {
		if _, err := parseDirectSend([]byte(raw)); err == nil {
			t.Fatal("invalid payload accepted", raw)
		}
	}
}

func TestDirectExtrasEmojiChecksBothLengthUnits(t *testing.T) {
	for _, value := range []struct {
		emoji string
		valid bool
	}{
		{"👍", true}, {strings.Repeat("👍", 8), true}, {strings.Repeat("👍", 9), false},
		{strings.Repeat("a", 17), false}, {strings.Repeat("界", 11), false}, {" ", false},
	} {
		encoded, _ := json.Marshal(map[string]string{"emoji": value.emoji})
		if _, err := parseDirectReaction(encoded); (err == nil) != value.valid {
			t.Fatal(value, err)
		}
	}
}

func TestDirectExtrasUpdatedEventContainsOnlyLiveMessageCoordinates(t *testing.T) {
	for _, value := range []struct {
		body  string
		valid bool
	}{
		{`{"conversation_id":7,"message_id":2,"server_id":"instance"}`, true},
		{`{"conversation_id":7,"message_id":2,"server_id":""}`, false},
		{`{"conversation_id":7,"message_id":2,"reactions":[]}`, false},
		{`{"conversation_id":7,"message_id":"2"}`, false},
	} {
		var data map[string]json.RawMessage
		if json.Unmarshal([]byte(value.body), &data) != nil || validDirectSocketEvent("direct_message_updated", data) != value.valid {
			t.Fatal(value)
		}
	}
}
