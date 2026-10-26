// Reviewed feature schema authority. Recorded steps are immutable; add a new step for changes.
function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}
export const moderationSettings = freeze([
  {
    "key": "auto_hide_report_threshold",
    "value": "10",
    "value_type": "number",
    "label": "Auto-hide threshold",
    "description": "Automatically flags content when report count reaches this number."
  },
  {
    "key": "require_note_on_reject",
    "value": "true",
    "value_type": "boolean",
    "label": "Require rejection note",
    "description": "Moderators should leave a note when rejecting or removing content."
  },
  {
    "key": "allow_moderator_claim",
    "value": "true",
    "value_type": "boolean",
    "label": "Allow queue claiming",
    "description": "Moderators can claim and release moderation cases."
  },
  {
    "key": "default_mute_hours",
    "value": "24",
    "value_type": "number",
    "label": "Default mute duration",
    "description": "Default number of hours for user mute actions."
  }
]);
const definitions = [
  {
    "id": "two-factor",
    "steps": [
      {
        "id": "t13-two-factor-seq_2fa_recovery_code_id",
        "kind": "sequence",
        "name": "SEQ_2FA_RECOVERY_CODE_ID",
        "sql": `CREATE SEQUENCE seq_2fa_recovery_code_id
START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE`,
        "targetTable": "N_USER_TWO_FACTOR_RECOVERY_CODES",
        "targetColumn": "RECOVERY_CODE_ID"
      },
      {
        "id": "t13-two-factor-seq_2fa_trusted_device_id",
        "kind": "sequence",
        "name": "SEQ_2FA_TRUSTED_DEVICE_ID",
        "sql": `CREATE SEQUENCE seq_2fa_trusted_device_id
START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE`,
        "targetTable": "N_USER_TWO_FACTOR_TRUSTED_DEVICES",
        "targetColumn": "TRUSTED_DEVICE_ID"
      },
      {
        "id": "t13-two-factor-n_user_two_factor_secrets",
        "kind": "table",
        "name": "N_USER_TWO_FACTOR_SECRETS",
        "sql": `CREATE TABLE n_user_two_factor_secrets (
user_id            NUMBER(10) PRIMARY KEY,
secret_encrypted   VARCHAR2(512) NOT NULL,
secret_iv          VARCHAR2(64) NOT NULL,
secret_auth_tag    VARCHAR2(64) NOT NULL,
confirmed_at       TIMESTAMP,
enabled_at         TIMESTAMP,
created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
updated_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
CONSTRAINT fk_2fa_secret_user FOREIGN KEY (user_id)
REFERENCES n_users(user_id) ON DELETE CASCADE
)`
      },
      {
        "id": "t13-two-factor-n_user_two_factor_recovery_codes",
        "kind": "table",
        "name": "N_USER_TWO_FACTOR_RECOVERY_CODES",
        "sql": `CREATE TABLE n_user_two_factor_recovery_codes (
recovery_code_id   NUMBER(15) PRIMARY KEY,
user_id            NUMBER(10) NOT NULL,
code_hash          VARCHAR2(255) NOT NULL,
used_at            TIMESTAMP,
created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
CONSTRAINT fk_2fa_recovery_user FOREIGN KEY (user_id)
REFERENCES n_users(user_id) ON DELETE CASCADE
)`
      },
      {
        "id": "t13-two-factor-n_user_two_factor_trusted_devices",
        "kind": "table",
        "name": "N_USER_TWO_FACTOR_TRUSTED_DEVICES",
        "sql": `CREATE TABLE n_user_two_factor_trusted_devices (
trusted_device_id  NUMBER(15) PRIMARY KEY,
user_id            NUMBER(10) NOT NULL,
device_fingerprint VARCHAR2(200) NOT NULL,
device_info        VARCHAR2(200),
ip_address         VARCHAR2(64),
user_agent         VARCHAR2(500),
expires_at         TIMESTAMP NOT NULL,
revoked_at         TIMESTAMP,
created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
last_used_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
CONSTRAINT fk_2fa_trusted_user FOREIGN KEY (user_id)
REFERENCES n_users(user_id) ON DELETE CASCADE,
CONSTRAINT uk_2fa_trusted_device UNIQUE (user_id, device_fingerprint)
)`
      },
      {
        "id": "t13-two-factor-n_auth_two_factor_challenges",
        "kind": "table",
        "name": "N_AUTH_TWO_FACTOR_CHALLENGES",
        "sql": `CREATE TABLE n_auth_two_factor_challenges (
challenge_id       VARCHAR2(80) PRIMARY KEY,
user_id            NUMBER(10) NOT NULL,
remember_me        NUMBER(1) DEFAULT 0 NOT NULL
CHECK (remember_me IN (0, 1)),
device_info        VARCHAR2(200),
device_fingerprint VARCHAR2(200),
ip_address         VARCHAR2(64),
user_agent         VARCHAR2(500),
expires_at         TIMESTAMP NOT NULL,
consumed_at        TIMESTAMP,
created_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
CONSTRAINT fk_2fa_challenge_user FOREIGN KEY (user_id)
REFERENCES n_users(user_id) ON DELETE CASCADE
)`
      },
      {
        "id": "t13-two-factor-idx_2fa_recovery_user",
        "kind": "index",
        "name": "IDX_2FA_RECOVERY_USER",
        "sql": `CREATE INDEX idx_2fa_recovery_user
ON n_user_two_factor_recovery_codes(user_id, used_at)`
      },
      {
        "id": "t13-two-factor-idx_2fa_challenge_user",
        "kind": "index",
        "name": "IDX_2FA_CHALLENGE_USER",
        "sql": `CREATE INDEX idx_2fa_challenge_user
ON n_auth_two_factor_challenges(user_id, expires_at, consumed_at)`
      },
      {
        "id": "t13-two-factor-idx_2fa_trusted_user",
        "kind": "index",
        "name": "IDX_2FA_TRUSTED_USER",
        "sql": `CREATE INDEX idx_2fa_trusted_user
ON n_user_two_factor_trusted_devices(user_id, expires_at, revoked_at)`
      }
    ]
  },
  {
    "id": "groups",
    "steps": [
      {
        "id": "t13-groups-n_groups.category",
        "kind": "column",
        "name": "N_GROUPS.CATEGORY",
        "sql": `ALTER TABLE n_groups ADD (category VARCHAR2(30))`
      },
      {
        "id": "t13-groups-n_group_tags",
        "kind": "table",
        "name": "N_GROUP_TAGS",
        "sql": `CREATE TABLE n_group_tags (
group_id NUMBER(19) NOT NULL,
tag VARCHAR2(50) NOT NULL,
tag_lower VARCHAR2(50) NOT NULL,
created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
CONSTRAINT pk_group_tags PRIMARY KEY (group_id, tag_lower),
CONSTRAINT fk_group_tags_group FOREIGN KEY (group_id)
REFERENCES n_groups(group_id) ON DELETE CASCADE
)`
      },
      {
        "id": "t13-groups-n_group_notification_preferences",
        "kind": "table",
        "name": "N_GROUP_NOTIFICATION_PREFERENCES",
        "sql": `CREATE TABLE n_group_notification_preferences (
user_id NUMBER(10) NOT NULL,
group_id NUMBER(19) NOT NULL,
is_enabled NUMBER(1) DEFAULT 1 NOT NULL,
updated_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
CONSTRAINT pk_group_notif_prefs PRIMARY KEY (user_id, group_id),
CONSTRAINT ck_group_notif_prefs_enabled CHECK (is_enabled IN (0, 1)),
CONSTRAINT fk_group_notif_prefs_user FOREIGN KEY (user_id)
REFERENCES n_users(user_id) ON DELETE CASCADE,
CONSTRAINT fk_group_notif_prefs_group FOREIGN KEY (group_id)
REFERENCES n_groups(group_id) ON DELETE CASCADE
)`
      }
    ]
  },
  {
    "id": "user-settings",
    "steps": [
      {
        "id": "t13-user-settings-n_user_settings.ai_sentiment_enabled",
        "kind": "column",
        "name": "N_USER_SETTINGS.AI_SENTIMENT_ENABLED",
        "sql": `ALTER TABLE n_user_settings ADD (
ai_sentiment_enabled NUMBER(1) DEFAULT 0 NOT NULL
CHECK (ai_sentiment_enabled IN (0, 1))
)`
      },
      {
        "id": "t13-user-settings-n_user_settings.ai_sentiment_model_id",
        "kind": "column",
        "name": "N_USER_SETTINGS.AI_SENTIMENT_MODEL_ID",
        "sql": `ALTER TABLE n_user_settings ADD (
ai_sentiment_model_id VARCHAR2(128)
)`
      },
      {
        "id": "t13-user-settings-n_user_settings.ai_sentiment_return_probabilities",
        "kind": "column",
        "name": "N_USER_SETTINGS.AI_SENTIMENT_RETURN_PROBABILITIES",
        "sql": `ALTER TABLE n_user_settings ADD (
ai_sentiment_return_probabilities NUMBER(1) DEFAULT 1 NOT NULL
CHECK (ai_sentiment_return_probabilities IN (0, 1))
)`
      },
      {
        "id": "t13-user-settings-n_user_settings.ai_sentiment_include_metadata",
        "kind": "column",
        "name": "N_USER_SETTINGS.AI_SENTIMENT_INCLUDE_METADATA",
        "sql": `ALTER TABLE n_user_settings ADD (
ai_sentiment_include_metadata NUMBER(1) DEFAULT 0 NOT NULL
CHECK (ai_sentiment_include_metadata IN (0, 1))
)`
      },
      {
        "id": "t13-user-settings-n_user_settings.ai_sentiment_top_k",
        "kind": "column",
        "name": "N_USER_SETTINGS.AI_SENTIMENT_TOP_K",
        "sql": `ALTER TABLE n_user_settings ADD (
ai_sentiment_top_k NUMBER(2) DEFAULT 3 NOT NULL
CHECK (ai_sentiment_top_k BETWEEN 1 AND 10)
)`
      }
    ]
  },
  {
    "id": "media",
    "steps": [
      {
        "id": "t13-media-n_media_assets.description",
        "kind": "column",
        "name": "N_MEDIA_ASSETS.DESCRIPTION",
        "sql": `ALTER TABLE n_media_assets ADD (description VARCHAR2(1000))`
      }
    ]
  },
  {
    "id": "moderation",
    "steps": [
      {
        "id": "t13-moderation-seq_moderation_report_id",
        "kind": "sequence",
        "name": "SEQ_MODERATION_REPORT_ID",
        "sql": `CREATE SEQUENCE seq_moderation_report_id START WITH 1100000 INCREMENT BY 1 NOCACHE NOCYCLE`,
        "targetTable": "N_MODERATION_REPORTS",
        "targetColumn": "REPORT_ID"
      },
      {
        "id": "t13-moderation-seq_moderation_case_id",
        "kind": "sequence",
        "name": "SEQ_MODERATION_CASE_ID",
        "sql": `CREATE SEQUENCE seq_moderation_case_id START WITH 1200000 INCREMENT BY 1 NOCACHE NOCYCLE`,
        "targetTable": "N_MODERATION_CASES",
        "targetColumn": "CASE_ID"
      },
      {
        "id": "t13-moderation-seq_moderation_action_id",
        "kind": "sequence",
        "name": "SEQ_MODERATION_ACTION_ID",
        "sql": `CREATE SEQUENCE seq_moderation_action_id START WITH 1300000 INCREMENT BY 1 NOCACHE NOCYCLE`,
        "targetTable": "N_MODERATION_ACTIONS",
        "targetColumn": "ACTION_ID"
      },
      {
        "id": "t13-moderation-seq_moderation_restriction_id",
        "kind": "sequence",
        "name": "SEQ_MODERATION_RESTRICTION_ID",
        "sql": `CREATE SEQUENCE seq_moderation_restriction_id START WITH 1400000 INCREMENT BY 1 NOCACHE NOCYCLE`,
        "targetTable": "N_MODERATION_USER_RESTRICTIONS",
        "targetColumn": "RESTRICTION_ID"
      },
      {
        "id": "t13-moderation-n_moderation_reports",
        "kind": "table",
        "name": "N_MODERATION_REPORTS",
        "sql": `CREATE TABLE n_moderation_reports (
report_id NUMBER(15) PRIMARY KEY,
target_type VARCHAR2(20) NOT NULL,
target_id NUMBER(15) NOT NULL,
reporter_user_id NUMBER(10),
reason VARCHAR2(30) NOT NULL,
description VARCHAR2(1000),
evidence_url VARCHAR2(1000),
status VARCHAR2(20) DEFAULT 'pending' NOT NULL,
priority VARCHAR2(20) DEFAULT 'normal' NOT NULL,
handled_by NUMBER(10),
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
resolved_at TIMESTAMP,
CONSTRAINT ck_mod_reports_target CHECK (target_type IN ('post', 'comment', 'user', 'group_post', 'group_comment')),
CONSTRAINT ck_mod_reports_reason CHECK (reason IN ('spam', 'harassment', 'hate', 'violence', 'adult', 'misinformation', 'copyright', 'other')),
CONSTRAINT ck_mod_reports_status CHECK (status IN ('pending', 'in_review', 'resolved', 'dismissed')),
CONSTRAINT ck_mod_reports_priority CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
CONSTRAINT fk_mod_reports_reporter FOREIGN KEY (reporter_user_id) REFERENCES n_users(user_id),
CONSTRAINT fk_mod_reports_handler FOREIGN KEY (handled_by) REFERENCES n_users(user_id)
)`
      },
      {
        "id": "t13-moderation-n_moderation_cases",
        "kind": "table",
        "name": "N_MODERATION_CASES",
        "sql": `CREATE TABLE n_moderation_cases (
case_id NUMBER(15) PRIMARY KEY,
target_type VARCHAR2(20) NOT NULL,
target_id NUMBER(15) NOT NULL,
status VARCHAR2(20) DEFAULT 'pending' NOT NULL,
priority VARCHAR2(20) DEFAULT 'normal' NOT NULL,
assigned_to NUMBER(10),
report_count NUMBER(10) DEFAULT 0 NOT NULL,
latest_reported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
resolved_at TIMESTAMP,
CONSTRAINT uk_mod_cases_target UNIQUE (target_type, target_id),
CONSTRAINT ck_mod_cases_target CHECK (target_type IN ('post', 'comment', 'user', 'group_post', 'group_comment')),
CONSTRAINT ck_mod_cases_status CHECK (status IN ('pending', 'approved', 'rejected', 'flagged', 'removed', 'restored')),
CONSTRAINT ck_mod_cases_priority CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
CONSTRAINT fk_mod_cases_assignee FOREIGN KEY (assigned_to) REFERENCES n_users(user_id)
)`
      },
      {
        "id": "t13-moderation-n_moderation_actions",
        "kind": "table",
        "name": "N_MODERATION_ACTIONS",
        "sql": `CREATE TABLE n_moderation_actions (
action_id NUMBER(15) PRIMARY KEY,
case_id NUMBER(15),
target_type VARCHAR2(20) NOT NULL,
target_id NUMBER(15) NOT NULL,
action VARCHAR2(30) NOT NULL,
moderator_user_id NUMBER(10) NOT NULL,
reason VARCHAR2(200),
note CLOB,
duration_hours NUMBER(10),
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
CONSTRAINT fk_mod_actions_case FOREIGN KEY (case_id) REFERENCES n_moderation_cases(case_id),
CONSTRAINT fk_mod_actions_user FOREIGN KEY (moderator_user_id) REFERENCES n_users(user_id)
)`
      },
      {
        "id": "t13-moderation-n_moderation_user_restrictions",
        "kind": "table",
        "name": "N_MODERATION_USER_RESTRICTIONS",
        "sql": `CREATE TABLE n_moderation_user_restrictions (
restriction_id NUMBER(15) PRIMARY KEY,
user_id NUMBER(10) NOT NULL,
restriction_type VARCHAR2(20) NOT NULL,
status VARCHAR2(20) DEFAULT 'active' NOT NULL,
reason VARCHAR2(200),
starts_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
ends_at TIMESTAMP,
created_by NUMBER(10) NOT NULL,
revoked_by NUMBER(10),
revoked_at TIMESTAMP,
CONSTRAINT ck_mod_restriction_type CHECK (restriction_type IN ('ban', 'mute')),
CONSTRAINT ck_mod_restriction_status CHECK (status IN ('active', 'revoked', 'expired')),
CONSTRAINT fk_mod_restriction_user FOREIGN KEY (user_id) REFERENCES n_users(user_id),
CONSTRAINT fk_mod_restriction_created FOREIGN KEY (created_by) REFERENCES n_users(user_id),
CONSTRAINT fk_mod_restriction_revoked FOREIGN KEY (revoked_by) REFERENCES n_users(user_id)
)`
      },
      {
        "id": "t13-moderation-n_moderation_settings",
        "kind": "table",
        "name": "N_MODERATION_SETTINGS",
        "sql": `CREATE TABLE n_moderation_settings (
setting_key VARCHAR2(80) PRIMARY KEY,
setting_value VARCHAR2(1000) NOT NULL,
value_type VARCHAR2(20) DEFAULT 'string' NOT NULL,
label VARCHAR2(120) NOT NULL,
description VARCHAR2(500),
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
updated_by NUMBER(10),
CONSTRAINT ck_mod_settings_type CHECK (value_type IN ('boolean', 'number', 'string')),
CONSTRAINT fk_mod_settings_user FOREIGN KEY (updated_by) REFERENCES n_users(user_id)
)`
      }
    ]
  }
];
definitions.find(feature => feature.id === 'moderation').steps.push(...moderationSettings.map(setting => ({
  kind: 'seed', name: setting.key, id: 't13-moderation-setting-' + setting.key, setting
})));
export const schemaFeatures = freeze(definitions);
