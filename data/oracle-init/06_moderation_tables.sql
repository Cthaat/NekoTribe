-- NekoTribe V2 moderation/report schema.

CREATE SEQUENCE seq_moderation_report_id START WITH 1100000 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_moderation_case_id START WITH 1200000 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_moderation_action_id START WITH 1300000 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_moderation_restriction_id START WITH 1400000 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE n_moderation_reports (
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
  CONSTRAINT ck_mod_reports_target CHECK (target_type IN ('post', 'comment', 'user')),
  CONSTRAINT ck_mod_reports_reason CHECK (reason IN ('spam', 'harassment', 'hate', 'violence', 'adult', 'misinformation', 'copyright', 'other')),
  CONSTRAINT ck_mod_reports_status CHECK (status IN ('pending', 'in_review', 'resolved', 'dismissed')),
  CONSTRAINT ck_mod_reports_priority CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
  CONSTRAINT fk_mod_reports_reporter FOREIGN KEY (reporter_user_id) REFERENCES n_users(user_id),
  CONSTRAINT fk_mod_reports_handler FOREIGN KEY (handled_by) REFERENCES n_users(user_id)
);

CREATE TABLE n_moderation_cases (
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
  CONSTRAINT ck_mod_cases_target CHECK (target_type IN ('post', 'comment', 'user')),
  CONSTRAINT ck_mod_cases_status CHECK (status IN ('pending', 'approved', 'rejected', 'flagged', 'removed', 'restored')),
  CONSTRAINT ck_mod_cases_priority CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
  CONSTRAINT fk_mod_cases_assignee FOREIGN KEY (assigned_to) REFERENCES n_users(user_id)
);

CREATE TABLE n_moderation_actions (
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
);

CREATE TABLE n_moderation_user_restrictions (
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
);

CREATE TABLE n_moderation_settings (
  setting_key VARCHAR2(80) PRIMARY KEY,
  setting_value VARCHAR2(1000) NOT NULL,
  value_type VARCHAR2(20) DEFAULT 'string' NOT NULL,
  label VARCHAR2(120) NOT NULL,
  description VARCHAR2(500),
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  updated_by NUMBER(10),
  CONSTRAINT ck_mod_settings_type CHECK (value_type IN ('boolean', 'number', 'string')),
  CONSTRAINT fk_mod_settings_user FOREIGN KEY (updated_by) REFERENCES n_users(user_id)
);

CREATE INDEX idx_mod_reports_target ON n_moderation_reports(target_type, target_id);
CREATE INDEX idx_mod_reports_status ON n_moderation_reports(status, created_at DESC);
CREATE INDEX idx_mod_cases_status ON n_moderation_cases(status, latest_reported_at DESC);
CREATE INDEX idx_mod_actions_target ON n_moderation_actions(target_type, target_id, created_at DESC);
CREATE INDEX idx_mod_restrictions_user ON n_moderation_user_restrictions(user_id, status);

INSERT INTO n_moderation_settings (setting_key, setting_value, value_type, label, description)
VALUES ('auto_hide_report_threshold', '10', 'number', 'Auto-hide threshold', 'Automatically flags content when report count reaches this number.');
INSERT INTO n_moderation_settings (setting_key, setting_value, value_type, label, description)
VALUES ('require_note_on_reject', 'true', 'boolean', 'Require rejection note', 'Moderators should leave a note when rejecting or removing content.');
INSERT INTO n_moderation_settings (setting_key, setting_value, value_type, label, description)
VALUES ('allow_moderator_claim', 'true', 'boolean', 'Allow queue claiming', 'Moderators can claim and release moderation cases.');
INSERT INTO n_moderation_settings (setting_key, setting_value, value_type, label, description)
VALUES ('default_mute_hours', '24', 'number', 'Default mute duration', 'Default number of hours for user mute actions.');

COMMIT;
