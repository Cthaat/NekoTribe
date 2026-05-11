import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import type {
  V2ModerationAppeal,
  V2ModerationContentItem,
  V2ModerationPriority,
  V2ModerationReport,
  V2ModerationReportReason,
  V2ModerationReportStatus,
  V2ModerationSetting,
  V2ModerationStats,
  V2ModerationStatus,
  V2ModerationTargetType,
  V2ModerationUserItem,
  V2PublicUser
} from '../../../app/types/v2';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2Count,
  v2DateString,
  v2Execute,
  v2Forbidden,
  v2NextId,
  v2NotFound,
  v2Number,
  v2NumberArray,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryString,
  v2RequiredNumber,
  v2Rows,
  v2String,
  v2StringOrNull,
  type V2DbRecord
} from '~/server/utils/v2';
import {
  v2GetPostMedia,
  v2MapPublicUser,
  v2RequirePublicUser
} from '~/server/models/v2';

interface V2ServiceResponse<T> {
  code: number;
  message: string;
  data: T;
  meta: {
    page?: number;
    page_size?: number;
    total?: number;
    has_next?: boolean;
    limit?: number;
  } | null;
}

const REPORT_REASONS = [
  'spam',
  'harassment',
  'hate',
  'violence',
  'adult',
  'misinformation',
  'copyright',
  'other'
] as const;

const PRIORITIES = [
  'low',
  'normal',
  'high',
  'urgent'
] as const;

const REPORT_STATUSES = [
  'pending',
  'in_review',
  'resolved',
  'dismissed'
] as const;

const CASE_STATUSES = [
  'pending',
  'approved',
  'rejected',
  'flagged',
  'removed',
  'restored'
] as const;

const TARGET_TYPES = ['post', 'comment', 'user'] as const;

interface ModerationSettingDefinition {
  key: string;
  value: string;
  value_type: V2ModerationSetting['value_type'];
  label: string;
  description: string;
}

const DEFAULT_SETTINGS: ModerationSettingDefinition[] = [
  {
    key: 'auto_hide_report_threshold',
    value: '10',
    value_type: 'number',
    label: 'Auto-hide threshold',
    description:
      'Automatically flags content when report count reaches this number.'
  },
  {
    key: 'require_note_on_reject',
    value: 'true',
    value_type: 'boolean',
    label: 'Require rejection note',
    description:
      'Moderators should leave a note when rejecting or removing content.'
  },
  {
    key: 'allow_moderator_claim',
    value: 'true',
    value_type: 'boolean',
    label: 'Allow queue claiming',
    description:
      'Moderators can claim and release moderation cases.'
  },
  {
    key: 'default_mute_hours',
    value: '24',
    value_type: 'number',
    label: 'Default mute duration',
    description:
      'Default number of hours for user mute actions.'
  }
];

let moderationSchemaReady = false;

function ensureValue<T extends readonly string[]>(
  values: T,
  value: string,
  fallback: T[number]
): T[number] {
  return (values as readonly string[]).includes(value)
    ? (value as T[number])
    : fallback;
}

function moderationReason(
  value: string
): V2ModerationReportReason {
  return ensureValue(REPORT_REASONS, value, 'other');
}

function moderationPriority(
  value: string
): V2ModerationPriority {
  return ensureValue(PRIORITIES, value, 'normal');
}

function moderationReportStatus(
  value: string
): V2ModerationReportStatus {
  return ensureValue(REPORT_STATUSES, value, 'pending');
}

function moderationCaseStatus(
  value: string
): V2ModerationStatus {
  return ensureValue(CASE_STATUSES, value, 'pending');
}

function moderationTargetType(
  value: string
): V2ModerationTargetType {
  return ensureValue(TARGET_TYPES, value, 'post');
}

function splitReasons(
  value: unknown
): V2ModerationReportReason[] {
  const seen = new Set<V2ModerationReportReason>();
  v2String(value)
    .split(',')
    .map(item => item.trim())
    .filter(Boolean)
    .forEach(item => seen.add(moderationReason(item)));
  return [...seen];
}

async function objectExists(
  connection: oracledb.Connection,
  type: 'TABLE' | 'SEQUENCE',
  name: string
): Promise<boolean> {
  const table =
    type === 'TABLE' ? 'user_tables' : 'user_sequences';
  const column =
    type === 'TABLE' ? 'table_name' : 'sequence_name';
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM ${table} WHERE ${column} = :name`,
    { name: name.toUpperCase() }
  );
  return total > 0;
}

async function executeDdl(
  connection: oracledb.Connection,
  sql: string
): Promise<void> {
  await connection.execute(sql);
}

async function createSequenceIfMissing(
  connection: oracledb.Connection,
  name: string,
  startWith: number
): Promise<void> {
  if (await objectExists(connection, 'SEQUENCE', name)) return;
  await executeDdl(
    connection,
    `CREATE SEQUENCE ${name} START WITH ${startWith} INCREMENT BY 1 NOCACHE NOCYCLE`
  );
}

async function createTableIfMissing(
  connection: oracledb.Connection,
  name: string,
  sql: string
): Promise<void> {
  if (await objectExists(connection, 'TABLE', name)) return;
  await executeDdl(connection, sql);
}

async function ensureDefaultSettings(
  connection: oracledb.Connection
): Promise<void> {
  for (const setting of DEFAULT_SETTINGS) {
    await v2Execute(
      connection,
      `
      MERGE INTO n_moderation_settings s
      USING (
        SELECT
          :setting_key AS setting_key,
          :setting_value AS setting_value,
          :value_type AS value_type,
          :label AS label,
          :description AS description
        FROM dual
      ) src
      ON (s.setting_key = src.setting_key)
      WHEN NOT MATCHED THEN
        INSERT (
          setting_key,
          setting_value,
          value_type,
          label,
          description
        ) VALUES (
          src.setting_key,
          src.setting_value,
          src.value_type,
          src.label,
          src.description
        )
      `,
      {
        setting_key: setting.key,
        setting_value: setting.value,
        value_type: setting.value_type,
        label: setting.label,
        description: setting.description
      }
    );
  }
}

async function ensureModerationSchema(
  connection: oracledb.Connection
): Promise<void> {
  if (moderationSchemaReady) return;

  await createSequenceIfMissing(
    connection,
    'seq_moderation_report_id',
    1100000
  );
  await createSequenceIfMissing(
    connection,
    'seq_moderation_case_id',
    1200000
  );
  await createSequenceIfMissing(
    connection,
    'seq_moderation_action_id',
    1300000
  );
  await createSequenceIfMissing(
    connection,
    'seq_moderation_restriction_id',
    1400000
  );

  await createTableIfMissing(
    connection,
    'n_moderation_reports',
    `
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
    )
    `
  );

  await createTableIfMissing(
    connection,
    'n_moderation_cases',
    `
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
    )
    `
  );

  await createTableIfMissing(
    connection,
    'n_moderation_actions',
    `
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
    )
    `
  );

  await createTableIfMissing(
    connection,
    'n_moderation_user_restrictions',
    `
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
    )
    `
  );

  await createTableIfMissing(
    connection,
    'n_moderation_settings',
    `
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
    )
    `
  );

  await ensureDefaultSettings(connection);
  moderationSchemaReady = true;
}

function mapUserFromRow(row: V2DbRecord): V2PublicUser {
  return v2MapPublicUser({
    USER_ID: row.USER_ID,
    USERNAME: row.USERNAME,
    AVATAR_URL: row.AVATAR_URL,
    DISPLAY_NAME: row.DISPLAY_NAME,
    BIO: row.BIO,
    LOCATION: row.LOCATION,
    WEBSITE: row.WEBSITE,
    IS_VERIFIED: row.IS_VERIFIED,
    FOLLOWERS_COUNT: row.FOLLOWERS_COUNT,
    FOLLOWING_COUNT: row.FOLLOWING_COUNT,
    POSTS_COUNT: row.POSTS_COUNT,
    LIKES_COUNT: row.LIKES_COUNT,
    RELATION: row.RELATION
  });
}

async function nullablePublicUser(
  connection: oracledb.Connection,
  viewerId: number,
  userId: number | null
): Promise<V2PublicUser | null> {
  if (!userId) return null;
  try {
    return await v2RequirePublicUser(connection, viewerId, userId);
  } catch {
    return null;
  }
}

async function reportsForTarget(
  connection: oracledb.Connection,
  viewerId: number,
  targetType: V2ModerationTargetType,
  targetId: number
): Promise<V2ModerationReport[]> {
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM n_moderation_reports
    WHERE target_type = :target_type
      AND target_id = :target_id
    ORDER BY created_at DESC
    `,
    {
      target_type: targetType,
      target_id: targetId
    }
  );
  return await Promise.all(
    rows.map(row => mapReport(connection, viewerId, row))
  );
}

async function mapReport(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2ModerationReport> {
  const reporterId = v2Number(row.REPORTER_USER_ID);
  const handlerId = v2Number(row.HANDLED_BY);
  return {
    report_id: v2Number(row.REPORT_ID),
    target_type: moderationTargetType(v2String(row.TARGET_TYPE)),
    target_id: v2Number(row.TARGET_ID),
    reporter: await nullablePublicUser(
      connection,
      viewerId,
      reporterId || null
    ),
    reason: moderationReason(v2String(row.REASON)),
    description: v2String(row.DESCRIPTION),
    evidence_url: v2StringOrNull(row.EVIDENCE_URL),
    status: moderationReportStatus(v2String(row.STATUS)),
    priority: moderationPriority(v2String(row.PRIORITY)),
    handled_by: await nullablePublicUser(
      connection,
      viewerId,
      handlerId || null
    ),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || '',
    resolved_at: v2DateString(row.RESOLVED_AT)
  };
}

async function ensureCaseForTarget(
  connection: oracledb.Connection,
  targetType: V2ModerationTargetType,
  targetId: number,
  priority: V2ModerationPriority = 'normal'
): Promise<number> {
  const existing = await v2One(
    connection,
    `
    SELECT case_id
    FROM n_moderation_cases
    WHERE target_type = :target_type
      AND target_id = :target_id
    `,
    {
      target_type: targetType,
      target_id: targetId
    }
  );
  if (existing) return v2Number(existing.CASE_ID);

  const caseId = await v2NextId(
    connection,
    'seq_moderation_case_id'
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_moderation_cases (
      case_id,
      target_type,
      target_id,
      status,
      priority,
      report_count,
      latest_reported_at
    ) VALUES (
      :case_id,
      :target_type,
      :target_id,
      'pending',
      :priority,
      0,
      CURRENT_TIMESTAMP
    )
    `,
    {
      case_id: caseId,
      target_type: targetType,
      target_id: targetId,
      priority
    }
  );
  return caseId;
}

async function syncCaseReportStats(
  connection: oracledb.Connection,
  targetType: V2ModerationTargetType,
  targetId: number
): Promise<void> {
  await ensureCaseForTarget(connection, targetType, targetId);
  await v2Execute(
    connection,
    `
    UPDATE n_moderation_cases c
    SET
      report_count = (
        SELECT COUNT(*)
        FROM n_moderation_reports r
        WHERE r.target_type = c.target_type
          AND r.target_id = c.target_id
      ),
      latest_reported_at = COALESCE((
        SELECT MAX(r.created_at)
        FROM n_moderation_reports r
        WHERE r.target_type = c.target_type
          AND r.target_id = c.target_id
      ), c.latest_reported_at),
      priority = COALESCE((
        SELECT MAX(r.priority) KEEP (
          DENSE_RANK LAST ORDER BY
            CASE r.priority
              WHEN 'urgent' THEN 4
              WHEN 'high' THEN 3
              WHEN 'normal' THEN 2
              ELSE 1
            END
        )
        FROM n_moderation_reports r
        WHERE r.target_type = c.target_type
          AND r.target_id = c.target_id
      ), c.priority),
      updated_at = CURRENT_TIMESTAMP
    WHERE c.target_type = :target_type
      AND c.target_id = :target_id
    `,
    {
      target_type: targetType,
      target_id: targetId
    }
  );
}

async function verifyTargetExists(
  connection: oracledb.Connection,
  targetType: V2ModerationTargetType,
  targetId: number
): Promise<void> {
  const table =
    targetType === 'post'
      ? 'n_posts'
      : targetType === 'comment'
        ? 'n_comments'
        : 'n_users';
  const column =
    targetType === 'post'
      ? 'post_id'
      : targetType === 'comment'
        ? 'comment_id'
        : 'user_id';
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM ${table} WHERE ${column} = :target_id`,
    { target_id: targetId }
  );
  if (total === 0) v2NotFound('举报目标不存在');
}

async function recordAction(
  connection: oracledb.Connection,
  data: {
    caseId: number | null;
    targetType: V2ModerationTargetType;
    targetId: number;
    action: string;
    moderatorUserId: number;
    reason?: string;
    note?: string;
    durationHours?: number | null;
  }
): Promise<void> {
  await v2Execute(
    connection,
    `
    INSERT INTO n_moderation_actions (
      action_id,
      case_id,
      target_type,
      target_id,
      action,
      moderator_user_id,
      reason,
      note,
      duration_hours
    ) VALUES (
      seq_moderation_action_id.NEXTVAL,
      :case_id,
      :target_type,
      :target_id,
      :action,
      :moderator_user_id,
      :reason,
      :note,
      :duration_hours
    )
    `,
    {
      case_id: data.caseId,
      target_type: data.targetType,
      target_id: data.targetId,
      action: data.action,
      moderator_user_id: data.moderatorUserId,
      reason: data.reason ?? null,
      note: data.note ?? null,
      duration_hours: data.durationHours ?? null
    }
  );
}

function contentWhere(
  event: H3Event,
  binds: Record<string, string | number | null>
): string {
  const where = ["c.target_type = 'post'"];
  const status = v2QueryString(event, 'status', 'all');
  const reason = v2QueryString(event, 'reason', 'all');
  const dateRange = v2QueryString(event, 'date_range', 'all');
  const q = v2QueryString(event, 'q').trim().toLowerCase();

  if (status && status !== 'all') {
    where.push('c.status = :status');
    binds.status = moderationCaseStatus(status);
  }
  if (reason && reason !== 'all') {
    where.push(`
      EXISTS (
        SELECT 1
        FROM n_moderation_reports rr
        WHERE rr.target_type = c.target_type
          AND rr.target_id = c.target_id
          AND rr.reason = :reason
      )
    `);
    binds.reason = moderationReason(reason);
  }
  if (q) {
    where.push(`
      (
        LOWER(DBMS_LOB.SUBSTR(p.content, 4000, 1)) LIKE :q
        OR LOWER(u.username) LIKE :q
        OR LOWER(COALESCE(u.display_name, u.username)) LIKE :q
      )
    `);
    binds.q = `%${q}%`;
  }
  if (dateRange === 'today') {
    where.push('c.latest_reported_at >= TRUNC(SYSDATE)');
  } else if (dateRange === 'yesterday') {
    where.push(`
      c.latest_reported_at >= TRUNC(SYSDATE) - 1
      AND c.latest_reported_at < TRUNC(SYSDATE)
    `);
  } else if (dateRange === 'week') {
    where.push("c.latest_reported_at >= SYSTIMESTAMP - INTERVAL '7' DAY");
  } else if (dateRange === 'month') {
    where.push("c.latest_reported_at >= SYSTIMESTAMP - INTERVAL '30' DAY");
  }

  return where.join('\nAND ');
}

function contentSort(event: H3Event): string {
  const sort = v2QueryString(event, 'sort', 'newest');
  if (sort === 'oldest') return 'c.latest_reported_at ASC';
  if (sort === 'most_reports') {
    return 'c.report_count DESC, c.latest_reported_at DESC';
  }
  if (sort === 'most_engagement') {
    return '(NVL(ps.likes_count, 0) + NVL(ps.retweets_count, 0) + NVL(ps.replies_count, 0)) DESC, c.latest_reported_at DESC';
  }
  return 'c.latest_reported_at DESC';
}

async function mapContentItem(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2ModerationContentItem> {
  const postId = v2Number(row.POST_ID);
  const assignedTo = v2Number(row.ASSIGNED_TO);
  return {
    case_id: v2Number(row.CASE_ID),
    post_id: postId,
    content: v2String(row.CONTENT),
    author: mapUserFromRow(row),
    media: await v2GetPostMedia(connection, postId),
    report_count: v2Number(row.REPORT_COUNT),
    report_reasons: splitReasons(row.REPORT_REASONS),
    reports: await reportsForTarget(
      connection,
      viewerId,
      'post',
      postId
    ),
    status: moderationCaseStatus(v2String(row.STATUS)),
    priority: moderationPriority(v2String(row.PRIORITY)),
    assigned_to: await nullablePublicUser(
      connection,
      viewerId,
      assignedTo || null
    ),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || '',
    reported_at: v2DateString(row.REPORTED_AT) || '',
    likes_count: v2Number(row.LIKES_COUNT_POST),
    retweets_count: v2Number(row.RETWEETS_COUNT),
    replies_count: v2Number(row.REPLIES_COUNT)
  };
}

export async function v2ListModerationContent(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationContentItem[]>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);

  const page = v2Page(event);
  const binds: Record<string, string | number | null> = {};
  const where = contentWhere(event, binds);
  const fromSql = `
    FROM n_moderation_cases c
    JOIN n_posts p
      ON p.post_id = c.target_id
     AND c.target_type = 'post'
    JOIN n_users u ON u.user_id = p.author_id
    LEFT JOIN n_user_stats us ON us.user_id = u.user_id
    LEFT JOIN n_post_stats ps ON ps.post_id = p.post_id
    LEFT JOIN (
      SELECT
        target_id,
        LISTAGG(reason, ',') WITHIN GROUP (ORDER BY reason) AS report_reasons
      FROM n_moderation_reports
      WHERE target_type = 'post'
      GROUP BY target_id
    ) rr ON rr.target_id = c.target_id
    WHERE ${where}
  `;

  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total ${fromSql}`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        c.case_id,
        c.status,
        c.priority,
        c.assigned_to,
        c.report_count,
        c.created_at,
        c.updated_at,
        c.latest_reported_at AS reported_at,
        p.post_id,
        DBMS_LOB.SUBSTR(p.content, 4000, 1) AS content,
        u.user_id,
        u.username,
        u.avatar_url,
        u.display_name,
        u.bio,
        u.location,
        u.website,
        u.is_verified,
        NVL(us.followers_count, 0) AS followers_count,
        NVL(us.following_count, 0) AS following_count,
        NVL(us.posts_count, 0) AS posts_count,
        NVL(us.likes_count, 0) AS likes_count,
        fn_get_user_relationship(:viewer_id, u.user_id) AS relation,
        NVL(ps.likes_count, 0) AS likes_count_post,
        NVL(ps.retweets_count, 0) AS retweets_count,
        NVL(ps.replies_count, 0) AS replies_count,
        rr.report_reasons,
        ROW_NUMBER() OVER (ORDER BY ${contentSort(event)}) AS rn
      ${fromSql}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      viewer_id: auth.userId,
      start_row: page.start,
      end_row: page.end
    }
  );

  const items = await Promise.all(
    rows.map(row =>
      mapContentItem(connection, auth.userId, row)
    )
  );

  return v2Ok(
    items,
    'moderation content listed',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2GetModerationStats(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationStats>> {
  v2Auth(event);
  await ensureModerationSchema(connection);

  const row = await v2One(
    connection,
    `
    SELECT
      (SELECT COUNT(*) FROM n_moderation_cases WHERE status = 'pending') AS pending,
      (SELECT COUNT(*) FROM n_moderation_cases WHERE status = 'approved') AS approved,
      (SELECT COUNT(*) FROM n_moderation_cases WHERE status = 'rejected') AS rejected,
      (SELECT COUNT(*) FROM n_moderation_cases WHERE status = 'flagged') AS flagged,
      (
        SELECT COUNT(*)
        FROM n_moderation_actions
        WHERE created_at >= TRUNC(SYSDATE)
          AND action IN ('approve', 'reject', 'flag', 'remove', 'restore', 'ban', 'mute')
      ) AS today_processed,
      (
        SELECT NVL(
          ROUND(
            AVG(
              (CAST(resolved_at AS DATE) - CAST(created_at AS DATE))
              * 24
              * 60
            )
          ),
          0
        )
        FROM n_moderation_cases
        WHERE resolved_at IS NOT NULL
      ) AS avg_process_minutes,
      (
        SELECT COUNT(*)
        FROM n_moderation_reports
        WHERE status IN ('pending', 'in_review')
      ) AS open_reports,
      (
        SELECT NVL(
          ROUND(
            SUM(CASE WHEN appeal_status = 'approved' THEN 1 ELSE 0 END)
            * 100
            / NULLIF(COUNT(*), 0)
          ),
          0
        )
        FROM n_statement_appeals
        WHERE appeal_status IN ('approved', 'rejected')
      ) AS appeal_success_rate
    FROM dual
    `
  );

  return v2Ok({
    pending: v2Number(row?.PENDING),
    approved: v2Number(row?.APPROVED),
    rejected: v2Number(row?.REJECTED),
    flagged: v2Number(row?.FLAGGED),
    today_processed: v2Number(row?.TODAY_PROCESSED),
    avg_process_minutes: v2Number(
      row?.AVG_PROCESS_MINUTES
    ),
    open_reports: v2Number(row?.OPEN_REPORTS),
    appeal_success_rate: v2Number(row?.APPEAL_SUCCESS_RATE)
  });
}

export async function v2ModeratePost(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2ServiceResponse<V2ModerationContentItem>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);
  await verifyTargetExists(connection, 'post', postId);

  const body = await v2Body(event);
  const action = v2String(body.action, 'flag');
  const note = v2String(body.note);
  const reason = v2String(body.reason);
  const validActions = [
    'approve',
    'reject',
    'flag',
    'remove',
    'restore',
    'claim',
    'release'
  ];
  if (!validActions.includes(action)) {
    v2BadRequest('action 参数错误');
  }

  const caseId = await ensureCaseForTarget(
    connection,
    'post',
    postId
  );
  const statusMap: Record<string, V2ModerationStatus> = {
    approve: 'approved',
    reject: 'rejected',
    flag: 'flagged',
    remove: 'removed',
    restore: 'restored',
    claim: 'pending',
    release: 'pending'
  };
  const reportStatusMap: Record<
    string,
    V2ModerationReportStatus
  > = {
    approve: 'dismissed',
    reject: 'resolved',
    flag: 'in_review',
    remove: 'resolved',
    restore: 'resolved',
    claim: 'in_review',
    release: 'pending'
  };

  if (action === 'reject' || action === 'remove') {
    await v2Execute(
      connection,
      `
      UPDATE n_posts
      SET is_deleted = 1,
          deleted_at = COALESCE(deleted_at, CURRENT_TIMESTAMP),
          updated_at = CURRENT_TIMESTAMP
      WHERE post_id = :post_id
      `,
      { post_id: postId },
      false
    );
  } else if (action === 'restore') {
    await v2Execute(
      connection,
      `
      UPDATE n_posts
      SET is_deleted = 0,
          deleted_at = NULL,
          updated_at = CURRENT_TIMESTAMP
      WHERE post_id = :post_id
      `,
      { post_id: postId },
      false
    );
  }

  await v2Execute(
    connection,
    `
    UPDATE n_moderation_cases
    SET status = :status,
        assigned_to = CASE
          WHEN :action = 'claim' THEN :moderator_user_id
          WHEN :action = 'release' THEN NULL
          ELSE assigned_to
        END,
        resolved_at = CASE
          WHEN :status IN ('approved', 'rejected', 'removed', 'restored')
          THEN CURRENT_TIMESTAMP
          ELSE resolved_at
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE case_id = :case_id
    `,
    {
      status: statusMap[action],
      action,
      moderator_user_id: auth.userId,
      case_id: caseId
    },
    false
  );

  await v2Execute(
    connection,
    `
    UPDATE n_moderation_reports
    SET status = :report_status,
        handled_by = :moderator_user_id,
        resolved_at = CASE
          WHEN :report_status IN ('resolved', 'dismissed')
          THEN CURRENT_TIMESTAMP
          ELSE resolved_at
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE target_type = 'post'
      AND target_id = :post_id
    `,
    {
      report_status: reportStatusMap[action],
      moderator_user_id: auth.userId,
      post_id: postId
    },
    false
  );

  await recordAction(connection, {
    caseId,
    targetType: 'post',
    targetId: postId,
    action,
    moderatorUserId: auth.userId,
    reason,
    note
  });
  await connection.commit();

  const row = await v2One(
    connection,
    `
    SELECT post_id
    FROM n_posts
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  if (!row) v2NotFound('帖子不存在');

  const listResponse = await v2ListModerationContent(
    event,
    connection
  );
  const item = listResponse.data.find(
    current => current.post_id === postId
  );
  if (item) return v2Ok(item, 'moderation action applied');

  const fallbackRow = await v2One(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        c.case_id,
        c.status,
        c.priority,
        c.assigned_to,
        c.report_count,
        c.created_at,
        c.updated_at,
        c.latest_reported_at AS reported_at,
        p.post_id,
        DBMS_LOB.SUBSTR(p.content, 4000, 1) AS content,
        u.user_id,
        u.username,
        u.avatar_url,
        u.display_name,
        u.bio,
        u.location,
        u.website,
        u.is_verified,
        NVL(us.followers_count, 0) AS followers_count,
        NVL(us.following_count, 0) AS following_count,
        NVL(us.posts_count, 0) AS posts_count,
        NVL(us.likes_count, 0) AS likes_count,
        fn_get_user_relationship(:viewer_id, u.user_id) AS relation,
        NVL(ps.likes_count, 0) AS likes_count_post,
        NVL(ps.retweets_count, 0) AS retweets_count,
        NVL(ps.replies_count, 0) AS replies_count,
        rr.report_reasons
      FROM n_moderation_cases c
      JOIN n_posts p ON p.post_id = c.target_id
      JOIN n_users u ON u.user_id = p.author_id
      LEFT JOIN n_user_stats us ON us.user_id = u.user_id
      LEFT JOIN n_post_stats ps ON ps.post_id = p.post_id
      LEFT JOIN (
        SELECT
          target_id,
          LISTAGG(reason, ',') WITHIN GROUP (ORDER BY reason) AS report_reasons
        FROM n_moderation_reports
        WHERE target_type = 'post'
        GROUP BY target_id
      ) rr ON rr.target_id = c.target_id
      WHERE c.target_type = 'post'
        AND c.target_id = :post_id
    )
    `,
    {
      viewer_id: auth.userId,
      post_id: postId
    }
  );
  if (!fallbackRow) v2NotFound('审核记录不存在');
  return v2Ok(
    await mapContentItem(connection, auth.userId, fallbackRow),
    'moderation action applied'
  );
}

export async function v2BulkModeratePosts(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<{ processed_count: number }>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);
  const body = await v2Body(event);
  const postIds = v2NumberArray(body.post_ids);
  const action = v2String(body.action, 'flag');
  const note = v2String(body.note);
  const reason = v2String(body.reason);
  if (postIds.length === 0) v2BadRequest('post_ids 不能为空');
  if (!['approve', 'reject', 'flag', 'remove', 'restore'].includes(action)) {
    v2BadRequest('action 参数错误');
  }

  const statusMap: Record<string, V2ModerationStatus> = {
    approve: 'approved',
    reject: 'rejected',
    flag: 'flagged',
    remove: 'removed',
    restore: 'restored'
  };
  const reportStatusMap: Record<
    string,
    V2ModerationReportStatus
  > = {
    approve: 'dismissed',
    reject: 'resolved',
    flag: 'in_review',
    remove: 'resolved',
    restore: 'resolved'
  };

  let processedCount = 0;
  for (const postId of postIds) {
    await verifyTargetExists(connection, 'post', postId);
    const caseId = await ensureCaseForTarget(
      connection,
      'post',
      postId
    );

    if (action === 'reject' || action === 'remove') {
      await v2Execute(
        connection,
        `
        UPDATE n_posts
        SET is_deleted = 1,
            deleted_at = COALESCE(deleted_at, CURRENT_TIMESTAMP),
            updated_at = CURRENT_TIMESTAMP
        WHERE post_id = :post_id
        `,
        { post_id: postId },
        false
      );
    } else if (action === 'restore') {
      await v2Execute(
        connection,
        `
        UPDATE n_posts
        SET is_deleted = 0,
            deleted_at = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE post_id = :post_id
        `,
        { post_id: postId },
        false
      );
    }

    await v2Execute(
      connection,
      `
      UPDATE n_moderation_cases
      SET status = :status,
          resolved_at = CASE
            WHEN :status IN ('approved', 'rejected', 'removed', 'restored')
            THEN CURRENT_TIMESTAMP
            ELSE resolved_at
          END,
          updated_at = CURRENT_TIMESTAMP
      WHERE case_id = :case_id
      `,
      {
        status: statusMap[action],
        case_id: caseId
      },
      false
    );
    await v2Execute(
      connection,
      `
      UPDATE n_moderation_reports
      SET status = :report_status,
          handled_by = :moderator_user_id,
          resolved_at = CASE
            WHEN :report_status IN ('resolved', 'dismissed')
            THEN CURRENT_TIMESTAMP
            ELSE resolved_at
          END,
          updated_at = CURRENT_TIMESTAMP
      WHERE target_type = 'post'
        AND target_id = :post_id
      `,
      {
        report_status: reportStatusMap[action],
        moderator_user_id: auth.userId,
        post_id: postId
      },
      false
    );
    await recordAction(connection, {
      caseId,
      targetType: 'post',
      targetId: postId,
      action,
      moderatorUserId: auth.userId,
      reason,
      note
    });
    processedCount++;
  }

  await connection.commit();
  return v2Ok(
    { processed_count: processedCount },
    'bulk moderation action applied'
  );
}

export async function v2CreateReport(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationReport>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);
  const body = await v2Body(event);
  const targetType = moderationTargetType(
    v2String(body.target_type)
  );
  const targetId = v2RequiredNumber(body.target_id, 'target_id');
  const reason = moderationReason(v2String(body.reason));
  const priority = moderationPriority(
    v2String(body.priority, 'normal')
  );

  await verifyTargetExists(connection, targetType, targetId);

  if (targetType === 'user' && targetId === auth.userId) {
    v2Forbidden('不能举报自己');
  }

  const reportId = await v2NextId(
    connection,
    'seq_moderation_report_id'
  );
  await v2Execute(
    connection,
    `
    INSERT INTO n_moderation_reports (
      report_id,
      target_type,
      target_id,
      reporter_user_id,
      reason,
      description,
      evidence_url,
      priority
    ) VALUES (
      :report_id,
      :target_type,
      :target_id,
      :reporter_user_id,
      :reason,
      :description,
      :evidence_url,
      :priority
    )
    `,
    {
      report_id: reportId,
      target_type: targetType,
      target_id: targetId,
      reporter_user_id: auth.userId,
      reason,
      description: v2String(body.description),
      evidence_url: v2StringOrNull(body.evidence_url),
      priority
    },
    false
  );
  await syncCaseReportStats(connection, targetType, targetId);
  await connection.commit();

  const row = await v2One(
    connection,
    `
    SELECT *
    FROM n_moderation_reports
    WHERE report_id = :report_id
    `,
    { report_id: reportId }
  );
  if (!row) v2NotFound('举报不存在');
  return v2Ok(
    await mapReport(connection, auth.userId, row),
    'report created'
  );
}

export async function v2ListModerationReports(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationReport[]>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);
  const page = v2Page(event);
  const status = v2QueryString(event, 'status', 'all');
  const reason = v2QueryString(event, 'reason', 'all');
  const targetType = v2QueryString(event, 'target_type', 'all');
  const binds: Record<string, string | number | null> = {};
  const where: string[] = ['1 = 1'];

  if (status !== 'all') {
    where.push('status = :status');
    binds.status = moderationReportStatus(status);
  }
  if (reason !== 'all') {
    where.push('reason = :reason');
    binds.reason = moderationReason(reason);
  }
  if (targetType !== 'all') {
    where.push('target_type = :target_type');
    binds.target_type = moderationTargetType(targetType);
  }

  const whereSql = where.join('\nAND ');
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM n_moderation_reports WHERE ${whereSql}`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT r.*, ROW_NUMBER() OVER (ORDER BY r.created_at DESC) AS rn
      FROM n_moderation_reports r
      WHERE ${whereSql}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  const reports = await Promise.all(
    rows.map(row => mapReport(connection, auth.userId, row))
  );
  return v2Ok(
    reports,
    'moderation reports listed',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2PatchModerationReport(
  event: H3Event,
  connection: oracledb.Connection,
  reportId: number
): Promise<V2ServiceResponse<V2ModerationReport>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);
  const body = await v2Body(event);
  const status = moderationReportStatus(v2String(body.status));
  await v2Execute(
    connection,
    `
    UPDATE n_moderation_reports
    SET status = :status,
        handled_by = :handled_by,
        resolved_at = CASE
          WHEN :status IN ('resolved', 'dismissed') THEN CURRENT_TIMESTAMP
          ELSE resolved_at
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE report_id = :report_id
    `,
    {
      status,
      handled_by: auth.userId,
      report_id: reportId
    }
  );
  const row = await v2One(
    connection,
    `
    SELECT *
    FROM n_moderation_reports
    WHERE report_id = :report_id
    `,
    { report_id: reportId }
  );
  if (!row) v2NotFound('举报不存在');
  return v2Ok(
    await mapReport(connection, auth.userId, row),
    'report updated'
  );
}

export async function v2ListModerationUsers(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationUserItem[]>> {
  v2Auth(event);
  await ensureModerationSchema(connection);
  const page = v2Page(event);
  const status = v2QueryString(event, 'status', 'all');
  const q = v2QueryString(event, 'q').trim().toLowerCase();
  const sort = v2QueryString(event, 'sort', 'newest');
  const binds: Record<string, string | number | null> = {};
  const where: string[] = ['1 = 1'];

  if (status !== 'all') {
    where.push('u.status = :status');
    binds.status = status;
  }
  if (q) {
    where.push(`
      (
        LOWER(u.username) LIKE :q
        OR LOWER(COALESCE(u.display_name, u.username)) LIKE :q
        OR LOWER(u.email) LIKE :q
      )
    `);
    binds.q = `%${q}%`;
  }
  const orderBy =
    sort === 'reports'
      ? 'u.report_count DESC, u.created_at DESC'
      : sort === 'oldest'
        ? 'u.created_at ASC'
        : 'u.created_at DESC';
  const whereSql = where.join('\nAND ');
  const fromSql = `
    FROM (
      SELECT
        u.user_id,
        u.email,
        u.username,
        u.avatar_url,
        u.display_name,
        u.is_verified,
        u.is_active,
        u.status,
        u.created_at,
        u.updated_at,
        NVL(us.followers_count, 0) AS followers_count,
        NVL(us.posts_count, 0) AS posts_count,
        NVL(us.likes_count, 0) AS likes_count,
        (
          SELECT COUNT(*)
          FROM n_moderation_reports r
          WHERE (
            r.target_type = 'user'
            AND r.target_id = u.user_id
          )
          OR (
            r.target_type = 'post'
            AND EXISTS (
              SELECT 1
              FROM n_posts p
              WHERE p.post_id = r.target_id
                AND p.author_id = u.user_id
            )
          )
        ) AS report_count,
        (
          SELECT restriction_type
          FROM (
            SELECT restriction_type
            FROM n_moderation_user_restrictions ur
            WHERE ur.user_id = u.user_id
              AND ur.status = 'active'
              AND (ur.ends_at IS NULL OR ur.ends_at > CURRENT_TIMESTAMP)
            ORDER BY ur.starts_at DESC
          )
          WHERE ROWNUM = 1
        ) AS active_restriction,
        (
          SELECT ends_at
          FROM (
            SELECT ends_at
            FROM n_moderation_user_restrictions ur
            WHERE ur.user_id = u.user_id
              AND ur.status = 'active'
              AND (ur.ends_at IS NULL OR ur.ends_at > CURRENT_TIMESTAMP)
            ORDER BY ur.starts_at DESC
          )
          WHERE ROWNUM = 1
        ) AS restriction_until
      FROM n_users u
      LEFT JOIN n_user_stats us ON us.user_id = u.user_id
    ) u
    WHERE ${whereSql}
  `;
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total ${fromSql}`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT u.*, ROW_NUMBER() OVER (ORDER BY ${orderBy}) AS rn
      ${fromSql}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );

  return v2Ok(
    rows.map(row => ({
      user_id: v2Number(row.USER_ID),
      username: v2String(row.USERNAME),
      display_name: v2String(row.DISPLAY_NAME),
      avatar_url: v2String(row.AVATAR_URL),
      email: v2String(row.EMAIL),
      status: v2String(row.STATUS),
      is_active: v2Number(row.IS_ACTIVE),
      is_verified: v2Number(row.IS_VERIFIED),
      followers_count: v2Number(row.FOLLOWERS_COUNT),
      posts_count: v2Number(row.POSTS_COUNT),
      likes_count: v2Number(row.LIKES_COUNT),
      report_count: v2Number(row.REPORT_COUNT),
      active_restriction: v2StringOrNull(
        row.ACTIVE_RESTRICTION
      ),
      restriction_until: v2DateString(row.RESTRICTION_UNTIL),
      created_at: v2DateString(row.CREATED_AT) || '',
      updated_at: v2DateString(row.UPDATED_AT) || ''
    })),
    'moderation users listed',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2ModerateUser(
  event: H3Event,
  connection: oracledb.Connection,
  userId: number
): Promise<V2ServiceResponse<V2ModerationUserItem>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);
  if (userId === auth.userId) v2Forbidden('不能处罚自己');
  await verifyTargetExists(connection, 'user', userId);
  const body = await v2Body(event);
  const action = v2String(body.action);
  const reason = v2String(body.reason);
  const note = v2String(body.note);
  const durationHours = v2Number(body.duration_hours, 24);

  if (
    !['ban', 'unban', 'mute', 'unmute', 'note'].includes(action)
  ) {
    v2BadRequest('action 参数错误');
  }

  const caseId = await ensureCaseForTarget(
    connection,
    'user',
    userId
  );

  if (action === 'ban') {
    await v2Execute(
      connection,
      `
      UPDATE n_users
      SET status = 'suspended',
          is_active = 0,
          updated_at = CURRENT_TIMESTAMP
      WHERE user_id = :user_id
      `,
      { user_id: userId },
      false
    );
    await v2Execute(
      connection,
      `
      INSERT INTO n_moderation_user_restrictions (
        restriction_id,
        user_id,
        restriction_type,
        reason,
        ends_at,
        created_by
      ) VALUES (
        seq_moderation_restriction_id.NEXTVAL,
        :user_id,
        'ban',
        :reason,
        CASE
          WHEN :duration_hours > 0
          THEN CURRENT_TIMESTAMP + NUMTODSINTERVAL(:duration_hours, 'HOUR')
          ELSE NULL
        END,
        :created_by
      )
      `,
      {
        user_id: userId,
        reason,
        duration_hours: durationHours,
        created_by: auth.userId
      },
      false
    );
  } else if (action === 'unban') {
    await v2Execute(
      connection,
      `
      UPDATE n_users
      SET status = 'active',
          is_active = 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE user_id = :user_id
      `,
      { user_id: userId },
      false
    );
    await revokeUserRestriction(
      connection,
      userId,
      'ban',
      auth.userId
    );
  } else if (action === 'mute') {
    await v2Execute(
      connection,
      `
      INSERT INTO n_moderation_user_restrictions (
        restriction_id,
        user_id,
        restriction_type,
        reason,
        ends_at,
        created_by
      ) VALUES (
        seq_moderation_restriction_id.NEXTVAL,
        :user_id,
        'mute',
        :reason,
        CURRENT_TIMESTAMP + NUMTODSINTERVAL(:duration_hours, 'HOUR'),
        :created_by
      )
      `,
      {
        user_id: userId,
        reason,
        duration_hours: Math.max(durationHours, 1),
        created_by: auth.userId
      },
      false
    );
  } else if (action === 'unmute') {
    await revokeUserRestriction(
      connection,
      userId,
      'mute',
      auth.userId
    );
  }

  await recordAction(connection, {
    caseId,
    targetType: 'user',
    targetId: userId,
    action,
    moderatorUserId: auth.userId,
    reason,
    note,
    durationHours
  });
  await connection.commit();

  const response = await v2ListModerationUsers(event, connection);
  const user = response.data.find(item => item.user_id === userId);
  if (!user) v2NotFound('用户不存在');
  return v2Ok(user, 'user moderation action applied');
}

async function revokeUserRestriction(
  connection: oracledb.Connection,
  userId: number,
  restrictionType: 'ban' | 'mute',
  moderatorUserId: number
): Promise<void> {
  await v2Execute(
    connection,
    `
    UPDATE n_moderation_user_restrictions
    SET status = 'revoked',
        revoked_by = :revoked_by,
        revoked_at = CURRENT_TIMESTAMP
    WHERE user_id = :user_id
      AND restriction_type = :restriction_type
      AND status = 'active'
    `,
    {
      revoked_by: moderatorUserId,
      user_id: userId,
      restriction_type: restrictionType
    },
    false
  );
}

export async function v2GetModerationSettings(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationSetting[]>> {
  v2Auth(event);
  await ensureModerationSchema(connection);
  const rows = await v2Rows(
    connection,
    `
    SELECT
      setting_key,
      setting_value,
      value_type,
      label,
      description,
      updated_at
    FROM n_moderation_settings
    ORDER BY setting_key
    `
  );
  return v2Ok(
    rows.map(row => ({
      key: v2String(row.SETTING_KEY),
      value: v2String(row.SETTING_VALUE),
      value_type: ensureValue(
        ['boolean', 'number', 'string'] as const,
        v2String(row.VALUE_TYPE),
        'string'
      ),
      label: v2String(row.LABEL),
      description: v2String(row.DESCRIPTION),
      updated_at: v2DateString(row.UPDATED_AT) || ''
    }))
  );
}

export async function v2PatchModerationSettings(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationSetting[]>> {
  const auth = v2Auth(event);
  await ensureModerationSchema(connection);
  const body = await v2Body(event);
  const settings = Array.isArray(body.settings)
    ? body.settings
    : [];

  for (const item of settings) {
    if (!item || typeof item !== 'object') continue;
    const record = item as Record<string, unknown>;
    const key = v2String(record.key);
    const value = v2String(record.value);
    const exists = DEFAULT_SETTINGS.some(
      setting => setting.key === key
    );
    if (!exists) continue;
    await v2Execute(
      connection,
      `
      UPDATE n_moderation_settings
      SET setting_value = :setting_value,
          updated_at = CURRENT_TIMESTAMP,
          updated_by = :updated_by
      WHERE setting_key = :setting_key
      `,
      {
        setting_value: value,
        updated_by: auth.userId,
        setting_key: key
      },
      false
    );
  }
  await connection.commit();
  return await v2GetModerationSettings(event, connection);
}

async function mapAppeal(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2ModerationAppeal> {
  const userRow = await v2One(
    connection,
    `
    SELECT
      u.user_id,
      u.username,
      u.avatar_url,
      u.display_name,
      u.bio,
      u.location,
      u.website,
      u.is_verified,
      NVL(us.followers_count, 0) AS followers_count,
      NVL(us.following_count, 0) AS following_count,
      NVL(us.posts_count, 0) AS posts_count,
      NVL(us.likes_count, 0) AS likes_count,
      fn_get_user_relationship(:viewer_id, u.user_id) AS relation
    FROM n_users u
    LEFT JOIN n_user_stats us ON us.user_id = u.user_id
    WHERE u.user_id = :user_id
    `,
    {
      viewer_id: viewerId,
      user_id: v2Number(row.USER_ID)
    }
  );
  if (!userRow) v2NotFound('用户不存在');
  return {
    appeal_id: v2Number(row.APPEAL_ID),
    statement_id: v2Number(row.STATEMENT_ID),
    user: mapUserFromRow(userRow),
    appeal_message: v2String(row.APPEAL_MESSAGE),
    appeal_status: ensureValue(
      ['pending', 'approved', 'rejected'] as const,
      v2String(row.APPEAL_STATUS),
      'pending'
    ),
    admin_response: v2String(row.ADMIN_RESPONSE),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2ListModerationAppeals(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2ServiceResponse<V2ModerationAppeal[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const status = v2QueryString(event, 'status', 'all');
  const binds: Record<string, string | number> = {};
  const where: string[] = ['1 = 1'];
  if (status !== 'all') {
    where.push('appeal_status = :status');
    binds.status = ensureValue(
      ['pending', 'approved', 'rejected'] as const,
      status,
      'pending'
    );
  }
  const whereSql = where.join('\nAND ');
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM n_statement_appeals WHERE ${whereSql}`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT a.*, ROW_NUMBER() OVER (ORDER BY a.created_at DESC) AS rn
      FROM n_statement_appeals a
      WHERE ${whereSql}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  const appeals = await Promise.all(
    rows.map(row => mapAppeal(connection, auth.userId, row))
  );
  return v2Ok(
    appeals,
    'moderation appeals listed',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2PatchModerationAppeal(
  event: H3Event,
  connection: oracledb.Connection,
  appealId: number
): Promise<V2ServiceResponse<V2ModerationAppeal>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const status = ensureValue(
    ['approved', 'rejected'] as const,
    v2String(body.appeal_status),
    'rejected'
  );
  const adminResponse = v2String(body.admin_response);
  const existing = await v2One(
    connection,
    `
    SELECT user_id
    FROM n_statement_appeals
    WHERE appeal_id = :appeal_id
    `,
    { appeal_id: appealId }
  );
  if (!existing) v2NotFound('申诉不存在');
  await v2Execute(
    connection,
    `
    UPDATE n_statement_appeals
    SET appeal_status = :appeal_status,
        admin_response = :admin_response,
        updated_at = CURRENT_TIMESTAMP
    WHERE appeal_id = :appeal_id
    `,
    {
      appeal_status: status,
      admin_response: adminResponse,
      appeal_id: appealId
    },
    false
  );
  await recordAction(connection, {
    caseId: null,
    targetType: 'user',
    targetId: v2Number(existing.USER_ID),
    action: `appeal_${status}`,
    moderatorUserId: auth.userId,
    note: adminResponse
  });
  await connection.commit();

  const row = await v2One(
    connection,
    `
    SELECT *
    FROM n_statement_appeals
    WHERE appeal_id = :appeal_id
    `,
    { appeal_id: appealId }
  );
  if (!row) v2NotFound('申诉不存在');
  return v2Ok(
    await mapAppeal(connection, auth.userId, row),
    'appeal updated'
  );
}

