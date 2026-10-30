package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

var errSettingsSchema = errors.New("user settings schema unavailable")

type userSettings struct {
	UserID                         int64   `json:"user_id"`
	TwoFactorEnabled               bool    `json:"two_factor_enabled"`
	LoginAlerts                    bool    `json:"login_alerts"`
	ProfileVisibility              string  `json:"profile_visibility"`
	ShowOnlineStatus               bool    `json:"show_online_status"`
	AllowDMFromStrangers           bool    `json:"allow_dm_from_strangers"`
	PushNotificationEnabled        bool    `json:"push_notification_enabled"`
	EmailNotificationEnabled       bool    `json:"email_notification_enabled"`
	AISentimentEnabled             bool    `json:"ai_sentiment_enabled"`
	AISentimentModelID             *string `json:"ai_sentiment_model_id"`
	AISentimentReturnProbabilities bool    `json:"ai_sentiment_return_probabilities"`
	AISentimentIncludeMetadata     bool    `json:"ai_sentiment_include_metadata"`
	AISentimentTopK                int64   `json:"ai_sentiment_top_k"`
	UpdatedAt                      string  `json:"updated_at"`
}

func (s OracleSessions) GetUserSettings(ctx context.Context, user int64) (userSettings, error) {
	return s.applyUserSettings(ctx, user, nil, verifyUserSettingsSchema)
}

func (s OracleSessions) PatchUserSettings(ctx context.Context, user int64, patch settingsPatch) (userSettings, error) {
	return s.applyUserSettings(ctx, user, &patch, verifyUserSettingsSchema)
}

func verifyUserSettingsSchema(ctx context.Context, conn *sql.Conn) error {
	var catalog schemaCatalog
	if json.Unmarshal(contracts.UserSettingsSchemaCatalog, &catalog) != nil || validateFeatureSchema(ctx, conn, catalog, "user-settings") != nil {
		return errSettingsSchema
	}
	return nil
}

func (s OracleSessions) applyUserSettings(ctx context.Context, user int64, patch *settingsPatch, verify func(context.Context, *sql.Conn) error) (result userSettings, err error) {
	if user <= 0 {
		return result, errSessionStore
	}
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return result, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			result = userSettings{}
			err = errSessionStore
		}
	}()
	if verify(ctx, conn) != nil {
		return result, errSettingsSchema
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return result, errSessionStore
	}
	committed := false
	defer func() {
		if !committed && tx.Rollback() != nil {
			result = userSettings{}
			err = errSessionStore
		}
	}()
	var lockedUser int64
	if err = tx.QueryRowContext(ctx, `SELECT user_id FROM n_users WHERE user_id=:user_id FOR UPDATE`, sql.Named("user_id", user)).Scan(&lockedUser); err != nil || lockedUser != user {
		return result, errSessionStore
	}
	const merge = `MERGE INTO n_user_settings s USING (SELECT :user_id AS user_id FROM dual) src ON (s.user_id = src.user_id) WHEN NOT MATCHED THEN INSERT (user_id) VALUES (src.user_id)`
	if _, err = tx.ExecContext(ctx, merge, sql.Named("user_id", user)); err != nil {
		return result, errSessionStore
	}
	if patch != nil {
		if query, args, ok := settingsUpdateStatement(user, *patch); ok {
			if _, err = tx.ExecContext(ctx, query, args...); err != nil {
				return result, errSessionStore
			}
		}
	}
	const query = `SELECT user_id,two_factor_enabled,login_alerts,profile_visibility,show_online_status,allow_dm_from_strangers,push_notification_enabled,email_notification_enabled,ai_sentiment_enabled,ai_sentiment_model_id,ai_sentiment_return_probabilities,ai_sentiment_include_metadata,ai_sentiment_top_k,updated_at FROM n_user_settings WHERE user_id=:user_id`
	var flags [9]sql.NullInt64
	var visibility, model sql.NullString
	var top sql.NullFloat64
	var updated sql.NullTime
	err = tx.QueryRowContext(ctx, query, sql.Named("user_id", user)).Scan(&result.UserID, &flags[0], &flags[1], &visibility, &flags[2], &flags[3], &flags[4], &flags[5], &flags[6], &model, &flags[7], &flags[8], &top, &updated)
	if err != nil {
		return userSettings{}, errSessionStore
	}
	result.TwoFactorEnabled = flags[0].Int64 == 1
	result.LoginAlerts = flags[1].Int64 == 1
	result.ProfileVisibility = visibility.String
	result.ShowOnlineStatus = flags[2].Int64 == 1
	result.AllowDMFromStrangers = flags[3].Int64 == 1
	result.PushNotificationEnabled = flags[4].Int64 == 1
	result.EmailNotificationEnabled = flags[5].Int64 == 1
	result.AISentimentEnabled = flags[6].Int64 == 1
	result.AISentimentModelID = nullableString(model)
	result.AISentimentReturnProbabilities = !flags[7].Valid || flags[7].Int64 == 1
	result.AISentimentIncludeMetadata = flags[8].Int64 == 1
	result.AISentimentTopK = 3
	if top.Valid && top.Float64 >= 1 && top.Float64 <= 10 {
		result.AISentimentTopK = int64(top.Float64)
	}
	if date := profileDate(updated); date != nil {
		result.UpdatedAt = *date
	}
	committed = true
	if tx.Commit() != nil {
		return userSettings{}, errSessionStore
	}
	return result, nil
}
