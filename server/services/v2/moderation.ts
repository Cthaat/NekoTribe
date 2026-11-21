import contentContract from '../../../specifications/requirements/moderation-content-queue.json';
import { requireFeatureSchema } from '~/server/database/readiness';
import { setResponseHeader } from 'h3';
import { readModerationUsers } from './moderation-user-queue';
import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import type {
  V2ModerationContentItem,
  V2ModerationPriority,
  V2ModerationReport,
  V2ModerationReportReason,
  V2ModerationReportStatus,
  V2ModerationStatus,
  V2ModerationTargetType,
  V2PublicUser
} from '../../../app/types/v2';
import {
  v2Auth,
  v2Body,
  v2DateString,
  v2Forbidden,
  v2Number,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryString,
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

const TARGET_TYPES = [
  'post',
  'comment',
  'user',
  'group_post',
  'group_comment'
] as const;

function moderationAdminAccounts(): Set<string> {
  return new Set((process.env.MODERATION_ADMIN_ACCOUNTS || '')
    .split(',')
    .map(item => item.trim().toLowerCase())
    .filter(Boolean));
}

function moderationAccessBypassEnabled(): boolean {
  return ['1', 'true', 'yes', 'on'].includes(
    String(process.env.MODERATION_ALLOW_ALL ?? '')
      .trim()
      .toLowerCase()
  );
}

export async function requireModerationAccess(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2AuthPayload> {
  const auth = v2Auth(event);
  if (moderationAccessBypassEnabled()) {
    return auth;
  }
  const allowedAccounts = moderationAdminAccounts();
  if (allowedAccounts.size === 0) v2Forbidden('需要审核权限');

  const row = await v2One(
    connection,
    `
    SELECT username, email
    FROM n_users
    WHERE user_id = :user_id
      AND is_active = 1
      AND status = 'active'
    `,
    { user_id: auth.userId }
  );
  const username = v2String(row?.USERNAME).toLowerCase();
  const email = v2String(row?.EMAIL).toLowerCase();
  if (
    allowedAccounts.has(username) ||
    allowedAccounts.has(email)
  ) {
    return auth;
  }

  v2Forbidden('需要审核权限');
}

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

export async function ensureModerationSchema(
  connection: oracledb.Connection
): Promise<void> {
  await requireFeatureSchema(connection, 'moderation');
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
    contentContract.sql.reports,
    {
      target_type: targetType,
      target_id: targetId
    }
  );
  return await Promise.all(
    rows.map(row => mapReport(connection, viewerId, row))
  );
}

export async function mapReport(
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

async function mapContentItem(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2ModerationContentItem> {
  const postId = v2Number(row.POST_ID);
  const assignedTo = v2Number(row.ASSIGNED_TO);
  const reports = await reportsForTarget(connection, viewerId, 'post', postId);
  return {
    case_id: v2Number(row.CASE_ID),
    post_id: postId,
    content: v2String(row.CONTENT),
    author: mapUserFromRow(row),
    media: await v2GetPostMedia(connection, postId),
    report_count: v2Number(row.REPORT_COUNT),
    report_reasons: [...new Set(reports.map(report => report.reason))].sort(),
    reports,
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

export async function readModerationContent(
  connection: oracledb.Connection,
  binds: {
    viewer_id: number;
    start_row: number;
    end_row: number;
    post_id?: number;
    status?: string | null;
    priority?: string | null;
    reason?: string | null;
    q?: string | null;
    date_range?: string;
    sort?: string;
  }
) {
  const rows = await v2Rows(connection, contentContract.sql.list, {
    post_id: null, status: null, priority: null, reason: null, q: null,
    sort: 'newest', date_range: 'all', ...binds
  });
  const items = await Promise.all(rows
    .filter(row => v2Number(row.CASE_ID) > 0)
    .map(row => mapContentItem(connection, binds.viewer_id, row)));
  return {items,total:v2Number(rows[0]?.TOTAL)};
}

export async function v2ListModerationContent(event: H3Event, connection: oracledb.Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const {userId} = await requireModerationAccess(event, connection);
  await ensureModerationSchema(connection);
  const page = v2Page(event);
  const status = v2QueryString(event,'status','all');
  const priority = v2QueryString(event,'priority','all');
  const reason = v2QueryString(event,'reason','all');
  const sort = v2QueryString(event,'sort','newest');
  const date = v2QueryString(event,'date_range','all');
  const {items,total} = await readModerationContent(connection, {
    viewer_id:userId, start_row:page.start, end_row:page.end,
    status:status && status !== 'all' ? moderationCaseStatus(status) : null,
    priority:contentContract.priorities.includes(priority) ? priority : null,
    reason:reason && reason !== 'all' ? moderationReason(reason) : null,
    q:v2QueryString(event,'q').trim() || null,
    date_range:contentContract.dates.includes(date) ? date : 'all',
    sort:contentContract.sorts.includes(sort) ? sort : 'newest'
  });
  return v2Ok(items,'moderation content listed',v2PageMeta(page.page,page.page_size,total));
}

export async function v2ListModerationUsers(event: H3Event, connection: oracledb.Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  await requireModerationAccess(event, connection);
  await ensureModerationSchema(connection);
  const page = v2Page(event);
  const {items,total} = await readModerationUsers(connection, {
    status: v2QueryString(event, 'status', 'all'),
    search: v2QueryString(event, 'q'),
    sort: v2QueryString(event, 'sort', 'newest'),
    start: page.start,
    end: page.end
  });
  return v2Ok(items,'moderation users listed',v2PageMeta(page.page,page.page_size,total));
}
