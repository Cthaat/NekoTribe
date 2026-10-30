package server

import (
	"database/sql"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestSharedUserSettingsPatchVectors(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/user-settings-patch.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ID    string `json:"id"`
		Cases []struct {
			ID       string                 `json:"id"`
			Body     map[string]interface{} `json:"body"`
			Fields   map[string]interface{} `json:"fields"`
			Presence bool                   `json:"presence"`
			Error    string                 `json:"error"`
		} `json:"cases"`
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.ID != "USER-SETTINGS-PATCH" || len(fixture.Cases) != 16 {
		t.Fatal("invalid fixture")
	}
	for _, tc := range fixture.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			got, err := parseSettingsPatch(tc.Body)
			if tc.Error != "" {
				if err == nil || err.Error() != tc.Error {
					t.Fatal(err)
				}
				return
			}
			if err != nil || got.PublishPresence != tc.Presence {
				t.Fatal(got, err)
			}
			actual, _ := json.Marshal(got.Fields)
			expected, _ := json.Marshal(tc.Fields)
			if string(actual) != string(expected) {
				t.Fatalf("got %s want %s", actual, expected)
			}
		})
	}
}

func TestSettingsPatchParsing(t *testing.T) {
	cases := []struct {
		name     string
		body     map[string]interface{}
		fields   map[string]interface{}
		presence bool
		err      string
	}{
		{"unknown ignored", map[string]interface{}{"unknown": 1}, map[string]interface{}{}, false, ""},
		{"boolean and presence", map[string]interface{}{"show_online_status": "YES", "login_alerts": " true "}, map[string]interface{}{"show_online_status": 1, "login_alerts": 0}, true, ""},
		{"restricted even null", map[string]interface{}{"two_factor_enabled": nil}, nil, false, "请通过双因素认证设置流程修改 two_factor_enabled"},
		{"visibility", map[string]interface{}{"profile_visibility": "private"}, map[string]interface{}{"profile_visibility": "private"}, false, ""},
		{"invalid visibility", map[string]interface{}{"profile_visibility": "PRIVATE"}, nil, false, "profile_visibility 参数错误"},
		{"clear model", map[string]interface{}{"ai_sentiment_model_id": "  "}, map[string]interface{}{"ai_sentiment_model_id": nil}, false, ""},
		{"utf16 model length", map[string]interface{}{"ai_sentiment_model_id": strings.Repeat("🐈", 65)}, nil, false, "ai_sentiment_model_id 长度不能超过 128"},
		{"decimal top k", map[string]interface{}{"ai_sentiment_top_k": 3.9}, map[string]interface{}{"ai_sentiment_top_k": 3}, false, ""},
		{"invalid number fallback", map[string]interface{}{"ai_sentiment_top_k": "abc"}, map[string]interface{}{"ai_sentiment_top_k": 3}, false, ""},
		{"hex top k", map[string]interface{}{"ai_sentiment_top_k": "0xa"}, map[string]interface{}{"ai_sentiment_top_k": 10}, false, ""},
		{"empty number rejected", map[string]interface{}{"ai_sentiment_top_k": ""}, nil, false, "ai_sentiment_top_k 必须在 1 到 10 之间"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseSettingsPatch(tc.body)
			if tc.err != "" {
				if err == nil || err.Error() != tc.err {
					t.Fatal(err)
				}
				return
			}
			if err != nil || got.PublishPresence != tc.presence || !reflect.DeepEqual(got.Fields, tc.fields) {
				t.Fatal(got, err)
			}
		})
	}
}

func TestSettingsUpdateStatementUsesAllowedColumnsAndScopedBinds(t *testing.T) {
	patch := settingsPatch{Fields: map[string]interface{}{"login_alerts": 1, "ai_sentiment_model_id": nil, "injected = 0 --": 1}}
	query, args, ok := settingsUpdateStatement(42, patch)
	if !ok || query != "UPDATE n_user_settings SET login_alerts = :login_alerts, ai_sentiment_model_id = :ai_sentiment_model_id, updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id" {
		t.Fatal(query, ok)
	}
	want := []interface{}{sql.Named("user_id", int64(42)), sql.Named("login_alerts", 1), sql.Named("ai_sentiment_model_id", nil)}
	if !reflect.DeepEqual(args, want) {
		t.Fatal(args)
	}
	if _, _, ok := settingsUpdateStatement(42, settingsPatch{Fields: map[string]interface{}{"injected": 1}}); ok {
		t.Fatal("unexpected update")
	}
}
