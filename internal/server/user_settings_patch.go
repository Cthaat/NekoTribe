package server

import (
	"database/sql"
	"errors"
	"math"
	"strings"
	"unicode/utf16"
)

var settingsWritableFields = [...]string{
	"login_alerts", "show_online_status", "allow_dm_from_strangers",
	"push_notification_enabled", "email_notification_enabled", "ai_sentiment_enabled",
	"ai_sentiment_return_probabilities", "ai_sentiment_include_metadata",
	"profile_visibility", "ai_sentiment_model_id", "ai_sentiment_top_k",
}

var settingsBooleanFields = [...]string{
	"login_alerts", "show_online_status", "allow_dm_from_strangers",
	"push_notification_enabled", "email_notification_enabled", "ai_sentiment_enabled",
	"ai_sentiment_return_probabilities", "ai_sentiment_include_metadata",
}

// settingsPatch contains only server-owned, allowlisted column names.
type settingsPatch struct {
	Fields          map[string]interface{}
	PublishPresence bool
}

func parseSettingsPatch(body map[string]interface{}) (settingsPatch, error) {
	result := settingsPatch{Fields: make(map[string]interface{})}
	if _, exists := body["two_factor_enabled"]; exists {
		return result, errors.New("请通过双因素认证设置流程修改 two_factor_enabled")
	}
	for _, key := range settingsBooleanFields {
		if value, exists := body[key]; exists {
			number := 0
			if readFlag(value) {
				number = 1
			}
			result.Fields[key] = number
			if key == "show_online_status" {
				result.PublishPresence = true
			}
		}
	}
	if value, exists := body["profile_visibility"]; exists {
		visibility := registrationString(value)
		if visibility != "public" && visibility != "private" {
			return result, errors.New("profile_visibility 参数错误")
		}
		result.Fields["profile_visibility"] = visibility
	}
	if value, exists := body["ai_sentiment_model_id"]; exists {
		model := strings.TrimFunc(registrationString(value), jsTrimSpace)
		if len(utf16.Encode([]rune(model))) > 128 {
			return result, errors.New("ai_sentiment_model_id 长度不能超过 128")
		}
		if model == "" {
			result.Fields["ai_sentiment_model_id"] = nil
		} else {
			result.Fields["ai_sentiment_model_id"] = model
		}
	}
	if value, exists := body["ai_sentiment_top_k"]; exists {
		number, ok := postNullableNumber(value)
		if s, isString := value.(string); isString && s == "" {
			number, ok = 0, true
		}
		if !ok {
			number = 3
		}
		number = math.Trunc(number)
		if number < 1 || number > 10 {
			return result, errors.New("ai_sentiment_top_k 必须在 1 到 10 之间")
		}
		result.Fields["ai_sentiment_top_k"] = int(number)
	}
	return result, nil
}

func settingsUpdateStatement(user int64, patch settingsPatch) (string, []interface{}, bool) {
	clauses := make([]string, 0, len(settingsWritableFields))
	args := []interface{}{sql.Named("user_id", user)}
	for _, field := range settingsWritableFields {
		if value, present := patch.Fields[field]; present {
			clauses = append(clauses, field+" = :"+field)
			args = append(args, sql.Named(field, value))
		}
	}
	if len(clauses) == 0 {
		return "", nil, false
	}
	return "UPDATE n_user_settings SET " + strings.Join(clauses, ", ") + ", updated_at = CURRENT_TIMESTAMP WHERE user_id = :user_id", args, true
}
