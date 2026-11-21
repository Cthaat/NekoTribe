import { requirePublishAccess } from './moderation-publish-policy';
import mediaReferences from '../../../specifications/requirements/media-delete-references.json';
import { managedPublicUrlToStorageKey } from '~/server/storage';
import { randomBytes } from 'node:crypto';
import { requireFeatureSchema } from '~/server/database/readiness';
import { getQuery, readRawBody, setResponseHeader, type H3Event } from 'h3';
import type oracledb from 'oracledb';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2BoolNumber,
  v2Boolean,
  v2Count,
  v2DateString,
  v2Execute,
  v2Forbidden,
  v2JsonValue,
  v2NextId,
  v2NotFound,
  v2Null,
  v2Number,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryNumber,
  v2QueryString,
  v2RequiredString,
  v2RouterParam,
  v2Rows,
  v2ServerError,
  v2String,
  v2StringArray,
  v2StringOrNull,
  v2Unprocessable,
  type V2DbRecord
} from '~/server/utils/v2';
import {
  v2GetPublicUser,
  v2MapGroup,
  v2MediaUrlArray,
  v2RequireGroup,
  v2RequirePublicUser
} from '~/server/models/v2';
import { logWarn } from '~/server/utils/logging';
import { v2CreateNotification, v2DeliverStoredNotification, v2StoreNotification } from './notifications';

function v2Slug(name: string, id: number): string {
  const suffix = `-${id}`;
  const normalized = name.toLowerCase().replace(/[^a-z0-9\u4e00-\u9fa5]+/g, '-').replace(/^-|-$/g, '');
  let base = '';
  for (const char of normalized) {
    if (Buffer.byteLength(base + char + suffix) > 100) break;
    base += char;
  }
  return (base.replace(/-$/, '') || 'group') + suffix;
}

function v2Privacy(value: string): string {
  if (['public', 'private', 'secret'].includes(value)) {
    return value;
  }
  v2BadRequest('privacy 参数错误');
}

function v2PostPermission(value: string): string {
  if (
    ['all', 'admin_only', 'moderator_up'].includes(value)
  ) {
    return value;
  }
  v2BadRequest('post_permission 参数错误');
}

const groupCategoryValues = [
  'tech',
  'game',
  'music',
  'art',
  'life',
  'study',
  'work',
  'other'
] as const;

function v2GroupCategoryOrNull(
  value: string | null
): V2GroupCategory | null {
  const normalized = (value ?? '').trim();
  if (!normalized) return null;
  if (
    groupCategoryValues.some(
      category => category === normalized
    )
  ) {
    return normalized as V2GroupCategory;
  }
  v2BadRequest('category 参数错误');
}

async function v2EnsureGroupFeatureSchema(
  connection: oracledb.Connection
): Promise<void> {
  await requireFeatureSchema(connection, 'groups');
}

async function v2ReplaceGroupTags(
  connection: oracledb.Connection,
  groupId: number,
  tags: string[]
): Promise<void> {
  await v2EnsureGroupFeatureSchema(connection);
  await v2Execute(
    connection,
    'DELETE FROM n_group_tags WHERE group_id = :group_id',
    { group_id: groupId },
    false
  );
  await v2InsertGroupTags(connection, groupId, tags);
}

async function v2InsertGroupTags(connection: oracledb.Connection, groupId: number, tags: string[]): Promise<void> {
  for (const tag of tags) {
    const affected = await v2Execute(
      connection,
      `
      INSERT INTO n_group_tags (group_id, tag, tag_lower)
      VALUES (:group_id, :tag, :tag_lower)
      `,
      {
        group_id: groupId,
        tag,
        tag_lower: tag.toLowerCase()
      },
      false
    );
    if (affected !== 1) v2ServerError();
  }
}

export async function v2GroupNotificationsEnabled(
  connection: oracledb.Connection,
  userId: number,
  groupId: number
): Promise<boolean> {
  await v2EnsureGroupFeatureSchema(connection);
  const row = await v2One(
    connection,
    `
    SELECT is_enabled
    FROM n_group_notification_preferences
    WHERE user_id = :user_id
      AND group_id = :group_id
    `,
    { user_id: userId, group_id: groupId }
  );
  return row ? v2Boolean(row.IS_ENABLED) : true;
}

const groupPostRecipientsSql = `SELECT m.user_id,g.name,COALESCE(u.display_name,u.username) AS actor_name
FROM n_group_members m
JOIN n_groups g ON g.group_id=m.group_id AND g.is_active=1 AND g.is_deleted=0
JOIN n_group_posts p ON p.group_id=g.group_id AND p.post_id=:post_id AND p.is_deleted=0 AND p.author_id=:actor_id
JOIN n_users u ON u.user_id=:actor_id AND u.is_active=1
JOIN n_users recipient ON recipient.user_id=m.user_id AND recipient.is_active=1
LEFT JOIN n_group_notification_preferences pref ON pref.group_id=g.group_id AND pref.user_id=m.user_id
WHERE g.group_id=:group_id AND m.status='active' AND m.user_id<>:actor_id AND NVL(pref.is_enabled,1)=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=m.user_id AND b.target_user_id=:actor_id)
       OR (b.target_user_id=m.user_id AND b.user_id=:actor_id))
ORDER BY m.user_id`;

async function v2NotifyGroupPostCreated(
  connection: oracledb.Connection,
  groupId: number,
  postId: number,
  actorId: number,
  content: string
): Promise<void> {
  const recipients = await v2Rows(connection, groupPostRecipientsSql, {
    group_id: groupId, actor_id: actorId, post_id: postId
  });
  const message = groupNoticeExcerpt(content);
  for (const recipient of recipients) {
    const userId = v2Number(recipient.USER_ID);
    const groupName = v2String(recipient.NAME, '群组');
    const actorName = v2String(recipient.ACTOR_NAME, '有人');
    const title = limitGroupNoticeTitle(`${actorName} 在 ${groupName} 发布了新帖子`);
    await v2CreateNotification(connection, {
      userId,
      actorId,
      type: 'group_post',
      title,
      message: message || '群组有一条新的帖子。',
      resourceType: 'group_post',
      resourceId: postId,
      priority: 'normal',
      metadata: {
        group_id: groupId,
        post_id: postId,
        event: 'group_post_created'
      }
    }).catch(() => logWarn('group-post:notification-failed', { groupId, postId, userId }));
  }
}

function groupNoticeExcerpt(content: string): string {
  const excerpt = content.trim().slice(0, 120);
  const last = excerpt.charCodeAt(excerpt.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? excerpt.slice(0, -1) : excerpt;
}

const groupCommentRecipientsSql = `WITH current_reply AS (
  SELECT c.comment_id,c.post_id,c.parent_comment_id,p.author_id AS post_author,g.group_id,g.name,g.privacy
  FROM n_group_comments c
  JOIN n_group_posts p ON p.post_id=c.post_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  JOIN n_groups g ON g.group_id=p.group_id AND g.is_active=1 AND g.is_deleted=0
  WHERE g.group_id=:group_id AND p.post_id=:post_id AND c.comment_id=:comment_id
    AND c.author_id=:actor_id AND c.is_deleted=0
), targets AS (
  SELECT post_author AS user_id FROM current_reply
  UNION
  SELECT parent.author_id AS user_id FROM current_reply r
  JOIN n_group_comments parent ON parent.comment_id=r.parent_comment_id
    AND parent.post_id=r.post_id AND parent.is_deleted=0
)
SELECT t.user_id,r.name AS group_name,COALESCE(u.display_name,u.username) AS actor_name
FROM targets t CROSS JOIN current_reply r
JOIN n_users u ON u.user_id=:actor_id AND u.is_active=1
JOIN n_users recipient ON recipient.user_id=t.user_id AND recipient.is_active=1
LEFT JOIN n_group_notification_preferences pref ON pref.group_id=r.group_id AND pref.user_id=t.user_id
WHERE t.user_id<>:actor_id AND NVL(pref.is_enabled,1)=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=t.user_id AND b.target_user_id IN (:actor_id,r.post_author))
       OR (b.target_user_id=t.user_id AND b.user_id IN (:actor_id,r.post_author)))
  AND (r.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
    WHERE m.group_id=r.group_id AND m.user_id=t.user_id AND m.status='active'))
ORDER BY t.user_id`;

async function v2NotifyGroupCommentCreated(
  connection: oracledb.Connection,
  { groupId, postId, commentId, actorId, content, parentCommentId }: {
    groupId: number; postId: number; commentId: number;
    actorId: number; content: string; parentCommentId: number | null;
  }
): Promise<void> {
  const rows = await v2Rows(connection, groupCommentRecipientsSql, {
    group_id: groupId, post_id: postId, comment_id: commentId, actor_id: actorId
  });
  const message = groupNoticeExcerpt(content) || '你的群组帖子有新评论。';
  for (const row of rows) {
    const userId = v2Number(row.USER_ID);
    await v2CreateNotification(connection, {
      userId,
      actorId,
      type: 'group_comment',
      title: limitGroupNoticeTitle(`${v2String(row.ACTOR_NAME)} 评论了 ${v2String(row.GROUP_NAME)} 的帖子`),
      message,
      resourceType: 'group_comment',
      resourceId: commentId,
      priority: 'normal',
      metadata: { group_id: groupId, post_id: postId, comment_id: commentId, parent_comment_id: parentCommentId, event: 'group_comment_created' }
    }).catch(() => logWarn('group-comment:notification-failed', { groupId, postId, commentId, userId }));
  }
}

function v2NormalizeInviteCode(code: string): string {
  return code.trim().toUpperCase();
}

export async function v2GroupPermission(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  role: string
): Promise<boolean> {
  const row = await v2One(
    connection,
    'SELECT fn_has_group_permission(:user_id, :group_id, :role) AS allowed FROM dual',
    { user_id: userId, group_id: groupId, role }
  );
  return v2Boolean(row?.ALLOWED);
}

async function v2ValidGroupInvite(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  inviteCode: string
): Promise<V2DbRecord | null> {
  const code = v2NormalizeInviteCode(inviteCode);
  if (!code) return null;

  return await v2One(
    connection,
    `
    SELECT invite_id, inviter_id
    FROM n_group_invites
    WHERE group_id = :group_id
      AND invite_code = :invite_code
      AND status = 'pending'
      AND (invitee_id IS NULL OR invitee_id = :user_id)
      AND (max_uses IS NULL OR used_count < max_uses)
      AND (expires_at IS NULL OR expires_at >= SYSTIMESTAMP)
    FETCH FIRST 1 ROWS ONLY
    `,
    {
      group_id: groupId,
      invite_code: code,
      user_id: userId
    }
  );
}

async function v2GroupIdByInviteCode(
  connection: oracledb.Connection,
  userId: number,
  inviteCode: string
): Promise<number> {
  const code = v2NormalizeInviteCode(inviteCode);
  if (!code) v2BadRequest('code 参数错误');

  const row = await v2One(
    connection,
    `
    SELECT group_id
    FROM n_group_invites
    WHERE invite_code = :invite_code
      AND status = 'pending'
      AND (invitee_id IS NULL OR invitee_id = :user_id)
      AND (max_uses IS NULL OR used_count < max_uses)
      AND (expires_at IS NULL OR expires_at >= SYSTIMESTAMP)
    FETCH FIRST 1 ROWS ONLY
    `,
    {
      invite_code: code,
      user_id: userId
    }
  );
  if (!row) v2Unprocessable('邀请码无效或已过期');
  return v2Number(row.GROUP_ID);
}

export async function v2ListGroups(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Group[]>> {
  await v2EnsureGroupFeatureSchema(connection);
  const auth = v2Auth(event);
  const page = v2Page(event);
  const q = v2QueryString(event, 'q').trim().toLowerCase();
  const privacy = v2StringOrNull(
    v2QueryString(event, 'privacy')
  );
  const category = v2GroupCategoryOrNull(
    v2StringOrNull(v2QueryString(event, 'category'))
  );
  const binds: Record<string, string | number | null> = {
    viewer_id: auth.userId,
    q: q ? `%${q}%` : null,
    privacy,
    category
  };
  const where = `
    WHERE is_deleted = 0
      AND is_active = 1
      AND (:privacy IS NULL OR privacy = :privacy)
      AND (:category IS NULL OR group_id IN (
        SELECT group_id FROM n_groups WHERE category = :category
      ))
      AND (:q IS NULL OR LOWER(group_name) LIKE :q OR LOWER(description) LIKE :q)
      AND (privacy = 'public' OR fn_can_view_group(:viewer_id, group_id) = 1)
  `;
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM v_group_details ${where}`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT g.*, ROW_NUMBER() OVER (
        ORDER BY member_count DESC, post_count DESC, created_at DESC, group_id DESC
      ) AS rn
      FROM v_group_details g
      ${where}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    ORDER BY rn
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  const groups = await Promise.all(
    rows.map(row =>
      v2MapGroup(connection, auth.userId, row)
    )
  );
  return v2Ok(
    groups,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2PopularGroups(
  event: H3Event,
  connection: oracledb.Connection
): Promise<
  V2Response<(V2Group & { activity_score: number })[]>
> {
  await v2EnsureGroupFeatureSchema(connection);
  const auth = v2Auth(event);
  const limit = Math.min(
    v2QueryNumber(event, 'limit', 10),
    50
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT g.*, p.activity_score
    FROM v_popular_groups p
    JOIN v_group_details g ON g.group_id = p.group_id
    ORDER BY p.activity_score DESC, p.member_count DESC, p.group_id DESC
    FETCH FIRST :limit ROWS ONLY
    `,
    { limit }
  );
  const groups = await Promise.all(
    rows.map(async row => ({
      ...(await v2MapGroup(connection, auth.userId, row)),
      activity_score: v2Number(row.ACTIVITY_SCORE)
    }))
  );
  return v2Ok(groups, 'success', { limit });
}

export async function v2MyGroups(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Group[]>> {
  await v2EnsureGroupFeatureSchema(connection);
  const auth = v2Auth(event);
  const page = v2Page(event);
  const q = v2QueryString(event, 'q').trim().toLowerCase();
  const privacy = v2StringOrNull(
    v2QueryString(event, 'privacy')
  );
  const category = v2GroupCategoryOrNull(
    v2StringOrNull(v2QueryString(event, 'category'))
  );
  const filters: Record<string, string | number | null> = {
    user_id: auth.userId,
    q: q ? `%${q}%` : null,
    privacy,
    category
  };
  const where = `
    WHERE ug.user_id = :user_id
      AND (:privacy IS NULL OR gd.privacy = :privacy)
      AND (:category IS NULL OR gd.group_id IN (
        SELECT group_id FROM n_groups WHERE category = :category
      ))
      AND (:q IS NULL OR LOWER(gd.group_name) LIKE :q OR LOWER(gd.description) LIKE :q)
  `;
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_user_groups ug
    JOIN v_group_details gd ON gd.group_id = ug.group_id
    ${where}
    `,
    filters
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        gd.*,
        ROW_NUMBER() OVER (ORDER BY ug.joined_at DESC, gd.group_id DESC) AS rn
      FROM v_user_groups ug
      JOIN v_group_details gd ON gd.group_id = ug.group_id
      ${where}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    ORDER BY rn
    `,
    {
      ...filters,
      start_row: page.start,
      end_row: page.end
    }
  );
  const groups = await Promise.all(
    rows.map(row =>
      v2MapGroup(connection, auth.userId, row)
    )
  );
  return v2Ok(
    groups,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateGroup(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Group>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const body = await groupModerationBody(event);
  const fields = v2GroupSettingsFields(body);
  if (typeof fields.name !== 'string') v2BadRequest('name 参数错误');
  const name = fields.name.trim();
  const tags = Object.hasOwn(body, 'tags') ? v2SettingsTags(body.tags) : [];
  await v2EnsureGroupFeatureSchema(connection);
  try {
    await v2LockGroupImages(connection, fields);
    const groupId = await v2NextId(connection, 'seq_group_id');
    if (!Number.isSafeInteger(groupId) || groupId < 1) v2ServerError();
    const identity = { group_id: groupId, owner_id: userId };
    if (await v2Execute(connection, `
      INSERT INTO n_groups
        (group_id,name,slug,description,avatar_url,cover_url,category,owner_id,privacy,join_approval,post_permission)
      VALUES
        (:group_id,:name,:slug,:description,:avatar_url,:cover_url,:category,:owner_id,:privacy,:join_approval,:post_permission)
    `, {
      ...identity, name, slug: v2Slug(name, groupId),
      description: fields.description ?? null, avatar_url: fields.avatar_url ?? null,
      cover_url: fields.cover_url ?? null, category: fields.category ?? null,
      privacy: fields.privacy ?? 'public', join_approval: fields.join_approval ?? 0,
      post_permission: fields.post_permission ?? 'all'
    }, false) !== 1 || await v2Execute(connection, `
      INSERT INTO n_group_members (group_id,user_id,role,status)
      VALUES (:group_id,:owner_id,'owner','active')
    `, identity, false) !== 1) v2ServerError();
    await v2InsertGroupTags(connection, groupId, tags);
    if (await v2Execute(connection, `
      INSERT INTO n_group_audit_logs (group_id,actor_id,action)
      VALUES (:group_id,:owner_id,'create_group')
    `, identity, false) !== 1) v2ServerError();
    const result = await v2RequireGroup(connection, userId, groupId).catch(() => v2ServerError());
    await connection.commit();
    return v2Ok(result, 'group created');
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2GetGroupById(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2Group>> {
  await v2EnsureGroupFeatureSchema(connection);
  return v2Ok(
    await v2RequireGroup(
      connection,
      v2Auth(event).userId,
      groupId
    )
  );
}

export async function v2GetGroupBySlug(
  event: H3Event,
  connection: oracledb.Connection,
  slug: string
): Promise<V2Response<V2Group>> {
  await v2EnsureGroupFeatureSchema(connection);
  const auth = v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT *
    FROM v_group_details
    WHERE slug = :slug
      AND is_deleted = 0
    `,
    { slug }
  );
  if (!row) v2NotFound('群组不存在');
  return v2Ok(
    await v2MapGroup(connection, auth.userId, row)
  );
}

function v2SettingsTags(input: unknown): string[] {
  if (!Array.isArray(input) || input.some(tag => typeof tag !== 'string')) v2BadRequest('tags 参数错误');
  const seen = new Set<string>();
  const tags: string[] = [];
  for (const raw of input as string[]) {
    const normalized = raw.trim().replace(/^#/, '').trim();
    let tag = '';
    for (const char of normalized) {
      if (Buffer.byteLength(tag + char) > 50) break;
      tag += char;
    }
    while (Buffer.byteLength(tag.toLowerCase()) > 50) tag = Array.from(tag).slice(0, -1).join('');
    const key = tag.toLowerCase();
    if (!tag || seen.has(key)) continue;
    seen.add(key);
    tags.push(tag);
    if (tags.length === 8) break;
  }
  return tags;
}

function v2GroupSettingsFields(body: Record<string, unknown>): Record<string, string | number | null> {
  const binds: Record<string, string | number | null> = {};
  for (const key of ['name', 'description', 'avatar_url', 'cover_url', 'privacy', 'join_approval', 'post_permission', 'category']) {
    if (!Object.hasOwn(body, key)) continue;
    const value = body[key];
    const invalid = () => v2BadRequest(`${key} 参数错误`);
    if (key === 'join_approval') {
      if (typeof value !== 'boolean') invalid();
      binds[key] = value ? 1 : 0;
    } else if (key === 'description' || key === 'avatar_url' || key === 'cover_url') {
      if (value !== null && (typeof value !== 'string' || Buffer.byteLength(value) > 500)) invalid();
      binds[key] = v2StringOrNull(value);
    } else if (key === 'category') {
      if (value !== null && typeof value !== 'string') invalid();
      binds[key] = v2GroupCategoryOrNull(v2StringOrNull(value));
    } else {
      if (typeof value !== 'string') v2BadRequest(`${key} 参数错误`);
      if (key === 'name' && (!value.trim() || Buffer.byteLength(value) > 100)) invalid();
      binds[key] = key === 'privacy' ? v2Privacy(value)
        : key === 'post_permission' ? v2PostPermission(value) : value;
    }
  }
  return binds;
}

const groupImageAlias = new RegExp(mediaReferences.aliasPattern);
const groupImageKey = new RegExp(mediaReferences.keyPattern);

async function v2LockGroupImages(
  connection: oracledb.Connection,
  fields: Record<string, string | number | null>
): Promise<void> {
  const names = ['avatar_url', 'cover_url'];
  const input = names.map(field => {
    const value = fields[field];
    return typeof value === 'string' ? value : '';
  });
  const urls = await v2LockGroupMediaUrls(connection, input, '群组图片不存在或已删除');
  for (const [index, field] of names.entries()) {
    if (urls[index] !== input[index] && urls[index] !== undefined) fields[field] = urls[index];
  }
}

async function v2LockGroupMediaUrls(
  connection: oracledb.Connection,
  urls: string[],
  missingMessage: string
): Promise<string[]> {
  const targets = new Map<number, string>();
  for (const [index, value] of urls.entries()) {
    const url = value.trim();
    let key: string | null = groupImageAlias.exec(url)?.[3] ?? null;
    if (key === null) {
      try {
        key = managedPublicUrlToStorageKey(url.split(/[?#]/, 1)[0] ?? '');
      } catch {
        continue;
      }
    }
    if (key && groupImageKey.test(key)) targets.set(index, key);
  }

  const keys = [...new Set(targets.values())];
  const assets: { id: number; key: string }[] = [];
  for (let i = 0; i < keys.length; i += 2) {
    const rows = await v2Rows(connection, mediaReferences.lookupGroupImages, {
      first_key: keys[i], second_key: keys[i + 1] ?? keys[i]
    });
    for (const row of rows) {
      const key = v2StringOrNull(row.STORAGE_KEY);
      const id = v2Number(row.MEDIA_ID);
      if (!key || !Number.isSafeInteger(id) || id < 1) v2ServerError();
      assets.push({ id, key });
    }
  }
  if (assets.length !== keys.length) v2BadRequest(missingMessage);

  const lockedUrls = new Map<string, string>();
  assets.sort((a, b) => a.id - b.id);
  for (const { id, key } of assets) {
    const locked = await v2One(connection, mediaReferences.lockGroupImage, { media_id: id, storage_key: key });
    const url = v2StringOrNull(locked?.PUBLIC_URL);
    if (!url) v2BadRequest(missingMessage);
    lockedUrls.set(key, url);
  }
  return urls.map((url, index) => {
    const key = targets.get(index);
    if (key === undefined) return url;
    const locked = lockedUrls.get(key);
    if (!locked) v2BadRequest(missingMessage);
    return locked;
  });
}

export async function v2PatchGroup(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Group>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const body = await groupModerationBody(event);
  const fields = v2GroupSettingsFields(body);
  const clauses = Object.keys(fields).map(key => `${key}=:${key}`);
  const tags = Object.hasOwn(body, 'tags') ? v2SettingsTags(body.tags) : null;
  await v2EnsureGroupFeatureSchema(connection);
  try {
    const group = await v2One(connection, groupMembershipLockSql, { group_id: groupId });
    if (!group || v2Number(group.IS_ACTIVE) !== 1 || v2Number(group.IS_DELETED) !== 0) v2NotFound('群组不存在');
    const actor = await v2One(connection, groupMembershipReadSql, { group_id: groupId, user_id: userId });
    if (actor?.STATUS !== 'active' || !(actor.ROLE === 'admin' || actor.ROLE === 'owner' && v2Number(group.OWNER_ID) === userId)) {
      v2Unprocessable('无权修改群组');
    }
    await v2LockGroupImages(connection, fields);
    if (clauses.length > 0 || tags !== null) {
      clauses.push('updated_at=SYSTIMESTAMP');
      if (await v2Execute(connection, `UPDATE n_groups SET ${clauses.join(',')} WHERE group_id=:group_id`, { group_id: groupId, ...fields }, false) !== 1) v2ServerError();
    }
    if (tags !== null) await v2ReplaceGroupTags(connection, groupId, tags);
    const result = await v2RequireGroup(connection, userId, groupId);
    await connection.commit();
    return v2Ok(result, 'group updated');
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2DeleteGroup(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<null>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const actor = v2Auth(event).userId;
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const groupBind = { group_id: groupId };
  const writeBind = { ...groupBind, actor_id: actor };
  try {
    const group = await v2One(connection, groupMembershipLockSql, groupBind);
    if (!group || v2Number(group.IS_DELETED) !== 0) v2NotFound('群组不存在');
    if (v2Number(group.OWNER_ID) !== actor) v2Unprocessable('只有群主可以解散群组');
    const member = await v2One(connection, groupMembershipReadSql, { ...groupBind, user_id: actor });
    if (member?.ROLE !== 'owner' || member.STATUS !== 'active') v2Unprocessable('只有群主可以解散群组');

    if (await v2Execute(connection, `
      UPDATE n_groups SET is_deleted=1,is_active=0
      WHERE group_id=:group_id AND owner_id=:actor_id AND is_deleted=0
    `, writeBind, false) !== 1 || await v2Execute(connection, `
      INSERT INTO n_group_audit_logs (group_id,actor_id,action) VALUES (:group_id,:actor_id,'delete_group')
    `, writeBind, false) !== 1) v2ServerError();
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  return v2Null('group deleted');
}

const groupPreferenceSql = `SELECT g.group_id, m.user_id AS member_id, COALESCE(p.is_enabled,1) AS is_enabled,
  p.updated_at
FROM n_groups g
LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:user_id AND m.status='active'
LEFT JOIN n_group_notification_preferences p ON p.group_id=g.group_id AND p.user_id=m.user_id
WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0`;
const saveGroupPreferenceSql = `MERGE INTO n_group_notification_preferences p
USING (SELECT :user_id AS user_id,:group_id AS group_id,:is_enabled AS is_enabled FROM dual) src
ON (p.user_id=src.user_id AND p.group_id=src.group_id)
WHEN MATCHED THEN UPDATE SET p.is_enabled=src.is_enabled,p.updated_at=SYSTIMESTAMP
WHEN NOT MATCHED THEN INSERT (user_id,group_id,is_enabled) VALUES (src.user_id,src.group_id,src.is_enabled)`;

async function readGroupPreference(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  denied: string
): Promise<V2GroupNotificationPreference> {
  const row = await v2One(connection, groupPreferenceSql, { user_id: userId, group_id: groupId });
  if (!row) v2NotFound('群组不存在');
  if (row.MEMBER_ID == null) v2Unprocessable(denied);
  return { user_id: userId, group_id: groupId, is_enabled: v2Boolean(row.IS_ENABLED), updated_at: v2DateString(row.UPDATED_AT) || '' };
}

export async function v2GetGroupNotificationPreference(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupNotificationPreference>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  await v2EnsureGroupFeatureSchema(connection);
  const preference = await readGroupPreference(connection, userId, groupId, '只有群组成员可以查看通知设置');
  return v2Ok({ ...preference, updated_at: preference.updated_at || new Date().toISOString() });
}

export async function v2PutGroupNotificationPreference(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupNotificationPreference>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const body = await groupModerationBody(event);
  const enabled = v2Boolean(body.is_enabled);
  await v2EnsureGroupFeatureSchema(connection);
  const binds = { user_id: userId, group_id: groupId };
  const denied = '只有群组成员可以修改通知设置';
  try {
    const group = await v2One(connection, `${groupContentSql} FOR UPDATE`, { group_id: groupId });
    if (!group) v2NotFound('群组不存在');
    await readGroupPreference(connection, userId, groupId, denied);
    if (await v2Execute(connection, saveGroupPreferenceSql, { ...binds, is_enabled: enabled ? 1 : 0 }, false) !== 1) v2ServerError();
    const saved = await readGroupPreference(connection, userId, groupId, denied).catch(() => v2ServerError());
    if (saved.is_enabled !== enabled) v2ServerError();
    await connection.commit();
    return v2Ok(saved, 'group notification preference updated');
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

type V2JoinGroupData = {
  member_id: number;
  group_id: number;
  user_id: number;
  role: string;
  status: string;
};

export async function v2JoinGroup(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2JoinGroupData>> {
  const raw = await readRawBody(event);
  let inviteCode: string | null = null;
  if (raw && Buffer.byteLength(raw, 'utf8') > 1024 * 1024) v2BadRequest('invite_code 参数错误');
  if (raw?.trim()) {
    let body: unknown;
    try { body = JSON.parse(raw); } catch { v2BadRequest('invite_code 参数错误'); }
    if (!body || typeof body !== 'object' || Array.isArray(body)) v2BadRequest('invite_code 参数错误');
    const code = (body as Record<string, unknown>).invite_code;
    if (code != null && typeof code !== 'string') v2BadRequest('invite_code 参数错误');
    inviteCode = v2NormalizeInviteCode(code ?? '') || null;
    if (inviteCode && Buffer.byteLength(inviteCode, 'utf8') > 32) v2BadRequest('invite_code 参数错误');
  }
  return await v2JoinGroupWithInviteCode(
    event,
    connection,
    groupId,
    inviteCode
  );
}

export async function v2JoinGroupByInviteCode(
  event: H3Event,
  connection: oracledb.Connection,
  code: string
): Promise<V2Response<V2JoinGroupData>> {
  const auth = v2Auth(event);
  const inviteCode = v2NormalizeInviteCode(code);
  const groupId = await v2GroupIdByInviteCode(
    connection,
    auth.userId,
    inviteCode
  );
  return await v2JoinGroupWithInviteCode(
    event,
    connection,
    groupId,
    inviteCode
  );
}

const groupMembershipLockSql = `SELECT owner_id, privacy, join_approval, is_active, is_deleted FROM n_groups WHERE group_id=:group_id FOR UPDATE`;
const groupMembershipReadSql = `SELECT role,status FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id FOR UPDATE`;

async function v2JoinGroupWithInviteCode(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number,
  inviteCode: string | null
): Promise<V2Response<V2JoinGroupData>> {
  const { userId } = v2Auth(event);
  const binds = { group_id: groupId, user_id: userId };
  try {
    const group = await v2One(connection, groupMembershipLockSql, { group_id: groupId });
    if (!group || v2Number(group.IS_ACTIVE) !== 1 || v2Number(group.IS_DELETED) !== 0) v2NotFound('群组不存在');
    if (await v2One(connection, groupMembershipReadSql, binds)) v2Unprocessable('您已经是群组成员');
    const privacy = v2String(group.PRIVACY);
    let status = privacy !== 'public' || v2Number(group.JOIN_APPROVAL) === 1 ? 'pending' : 'active';
    let invitedBy: number | null = null;
    if (inviteCode) {
      const invite = await v2ValidGroupInvite(connection, userId, groupId, inviteCode);
      if (!invite) v2Unprocessable('邀请码无效或已过期');
      const affected = await v2Execute(connection, `UPDATE n_group_invites SET used_count=used_count+1,
status=CASE WHEN max_uses IS NOT NULL AND used_count+1>=max_uses THEN 'accepted' ELSE status END,
responded_at=CASE WHEN max_uses IS NOT NULL AND used_count+1>=max_uses THEN SYSTIMESTAMP ELSE responded_at END
WHERE invite_id=:invite_id AND group_id=:group_id AND invite_code=:invite_code
AND status='pending' AND (invitee_id IS NULL OR invitee_id=:user_id)
AND (max_uses IS NULL OR used_count<max_uses) AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)`,
        { ...binds, invite_id: v2Number(invite.INVITE_ID), invite_code: inviteCode }, false);
      if (affected === 0) v2Unprocessable('邀请码无效或已过期');
      if (affected !== 1) v2ServerError();
      invitedBy = v2Number(invite.INVITER_ID);
      status = 'active';
    } else if (privacy === 'secret') {
      v2Unprocessable('该群组仅限邀请加入');
    }
    const memberId = await v2NextId(connection, 'seq_group_member_id');
    if (!Number.isSafeInteger(memberId) || memberId <= 0) v2ServerError();
    if (await v2Execute(connection, `INSERT INTO n_group_members (member_id,group_id,user_id,role,status,invited_by)
VALUES (:member_id,:group_id,:user_id,'member',:status,:invited_by)`,
      { ...binds, member_id: memberId, status, invited_by: invitedBy }, false) !== 1) v2ServerError();
    await connection.commit();
    return v2Ok({ member_id: memberId, group_id: groupId, user_id: userId, role: 'member', status },
      status === 'active' ? 'joined' : 'pending approval');
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2LeaveGroup(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<null>> {
  const { userId } = v2Auth(event);
  const binds = { group_id: groupId, user_id: userId };
  try {
    const group = await v2One(connection, groupMembershipLockSql, { group_id: groupId });
    if (!group) v2NotFound('成员不存在');
    const member = await v2One(connection, groupMembershipReadSql, binds);
    if (!member) v2NotFound('成员不存在');
    if (member.ROLE === 'owner' || v2Number(group.OWNER_ID) === userId) v2Unprocessable('群主不能退出群组');
    if (member.STATUS === 'banned') v2Unprocessable('被封禁的成员不能退出群组');
    if (await v2Execute(connection, `DELETE FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id AND role<>'owner' AND status<>'banned'`, binds, false) !== 1) v2ServerError();
    await connection.commit();
    return v2Null('left group');
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

const groupMemberListSql = `WITH group_scope AS (
  SELECT g.group_id, CASE
    WHEN viewer.status='banned' THEN 0
    WHEN viewer.status='active' AND viewer.role IN ('owner','admin','moderator') THEN 2
    WHEN g.privacy='public' OR viewer.status IN ('active','muted') THEN 1
    ELSE 0 END AS access_level
  FROM n_groups g
  LEFT JOIN n_group_members viewer ON viewer.group_id=g.group_id AND viewer.user_id=:viewer_id
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
), eligible AS (
  SELECT m.member_id,m.user_id,m.role,m.role_desc,m.status,m.nickname,m.joined_at,
    CASE WHEN s.access_level=2 OR m.user_id=:viewer_id THEN m.mute_until END AS mute_until,
    ROW_NUMBER() OVER (ORDER BY CASE m.role WHEN 'owner' THEN 1 WHEN 'admin' THEN 2
      WHEN 'moderator' THEN 3 ELSE 4 END,m.joined_at ASC,m.member_id ASC) AS rn
  FROM group_scope s
  JOIN v_group_member_details m ON m.group_id=s.group_id
  JOIN v_user_profile_public p ON p.user_id=m.user_id AND p.is_active=1
  WHERE s.access_level>0
    AND (s.access_level=2 OR m.status IN ('active','muted'))
    AND (:role_filter IS NULL OR m.role=:role_filter)
    AND (:status_filter IS NULL OR m.status=:status_filter)
)
SELECT s.access_level,c.total,m.member_id,m.user_id,m.role,m.role_desc,m.status,m.nickname,m.joined_at,m.mute_until
FROM group_scope s
CROSS JOIN (SELECT COUNT(*) AS total FROM eligible) c
LEFT JOIN eligible m ON m.rn BETWEEN :start_row AND :end_row
ORDER BY m.rn`;

export async function v2GroupMembers(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2GroupMember[]>> {
  const { userId } = v2Auth(event);
  const page = v2Page(event);
  const query = getQuery(event);
  const filter = (key: string, choices: string[]) => {
    const value = query[key];
    if (value === undefined || value === '') return null;
    if (typeof value !== 'string' || !choices.includes(value)) v2BadRequest(`${key} 参数错误`);
    return value;
  };
  const rows = await v2Rows(connection, groupMemberListSql, {
    viewer_id: userId,
    group_id: groupId,
    role_filter: filter('role', ['owner', 'admin', 'moderator', 'member']),
    status_filter: filter('status', ['pending', 'active', 'muted', 'banned']),
    start_row: page.start,
    end_row: page.end
  });
  const scope = rows[0];
  if (!scope) v2NotFound('群组不存在');
  if (v2Number(scope.ACCESS_LEVEL) === 0) v2Forbidden('无权查看群组成员');
  const total = v2Number(scope.TOTAL);
  const members: V2GroupMember[] = [];
  for (const row of rows) {
    if (row.MEMBER_ID == null) continue;
    members.push({
      member_id: v2Number(row.MEMBER_ID),
      user: await v2RequirePublicUser(connection, userId, v2Number(row.USER_ID)),
      role: v2String(row.ROLE) as V2GroupRole,
      role_desc: v2String(row.ROLE_DESC),
      status: v2String(row.STATUS),
      nickname: v2StringOrNull(row.NICKNAME),
      mute_until: v2DateString(row.MUTE_UNTIL),
      joined_at: v2DateString(row.JOINED_AT) || ''
    });
  }
  return v2Ok(
    members,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

type GroupAdmissionAction =
  | { kind: 'approve_member' | 'reject_member' | 'remove_member' | 'unmute_member' }
  | { kind: 'change_role'; role: Exclude<V2GroupRole, 'owner'> }
  | { kind: 'mute_member'; hours: number; reason: string | null };

const groupApprovalTargetSql = `SELECT user_id,role,status FROM n_group_members WHERE group_id=:group_id AND member_id=:member_id FOR UPDATE`;
const groupApproveSql = `UPDATE n_group_members SET status='active' WHERE group_id=:group_id AND member_id=:member_id AND status='pending' AND role='member'`;
const groupRejectSql = `DELETE FROM n_group_members WHERE group_id=:group_id AND member_id=:member_id AND status='pending' AND role='member'`;
const groupAdmissionAuditSql = `INSERT INTO n_group_audit_logs (group_id,actor_id,target_user_id,action,details) VALUES (:group_id,:actor_id,:target_user_id,:action,:details)`;
const groupMemberRoleSql = `UPDATE n_group_members SET role=:role WHERE group_id=:group_id AND user_id=:user_id AND status IN ('active','muted') AND role<>'owner'`;
const groupMuteSql = `UPDATE n_group_members SET status='muted',mute_until=SYSTIMESTAMP+NUMTODSINTERVAL(:hours,'HOUR'),ban_reason=:reason WHERE group_id=:group_id AND user_id=:user_id AND status IN ('active','muted') AND role<>'owner'`;
const groupUnmuteSql = `UPDATE n_group_members SET status='active',mute_until=NULL,ban_reason=NULL WHERE group_id=:group_id AND user_id=:user_id AND status='muted' AND role<>'owner'`;
const groupMuteUntilSql = `SELECT TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(mute_until,TO_CHAR(SYSTIMESTAMP,'TZH:TZM'))),'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS mute_until FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id`;
const groupRemoveMemberSql = `DELETE FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id AND role<>'owner' AND status<>'banned'`;

function groupAdmissionId(event: H3Event, name: string, label: string): number {
  let raw: string;
  try { raw = decodeURIComponent(v2RouterParam(event, name)); }
  catch { v2BadRequest(label); }
  const id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(id)) v2BadRequest(label);
  return id;
}

function groupMemberRank(role: unknown): number {
  return ['member', 'moderator', 'admin', 'owner'].findIndex(value => value === role) + 1;
}

async function changeGroupAdmission(
  connection: oracledb.Connection,
  viewer: number,
  groupId: number,
  target: number,
  action: GroupAdmissionAction
): Promise<string | null> {
  const groupBind = { group_id: groupId };
  const approval = action.kind === 'approve_member' || action.kind === 'reject_member';
  const moderation = action.kind === 'change_role' || action.kind === 'mute_member' || action.kind === 'unmute_member';
  const permission = {
    approve_member: '无权审批成员', reject_member: '无权审批成员', remove_member: '无权移除成员',
    change_role: '无权修改角色', mute_member: '无权禁言成员', unmute_member: '无权解除禁言'
  }[action.kind];
  try {
    const group = await v2One(connection, groupMembershipLockSql, groupBind);
    if (!group || v2Number(group.IS_ACTIVE) !== 1 || v2Number(group.IS_DELETED) !== 0) v2NotFound('群组不存在');
    const actor = await v2One(connection, groupMembershipReadSql, { ...groupBind, user_id: viewer });
    const rank = groupMemberRank(actor?.ROLE);
    if (actor?.STATUS !== 'active' || rank < (action.kind === 'change_role' ? 3 : 2)) v2Unprocessable(permission);

    const binds = approval ? { ...groupBind, member_id: target } : { ...groupBind, user_id: target };
    const member = await v2One(connection, approval ? groupApprovalTargetSql : groupMembershipReadSql, binds);
    if (!member) v2NotFound('成员不存在');
    const userId = approval ? v2Number(member.USER_ID) : target;
    const targetRank = groupMemberRank(member.ROLE);
    if (userId === viewer || userId === v2Number(group.OWNER_ID) || !targetRank || targetRank >= rank || member.STATUS === 'banned') {
      v2Unprocessable(permission);
    }
    if (moderation && member.STATUS !== 'active' && member.STATUS !== 'muted') v2Unprocessable(permission);
    if (approval && (member.ROLE !== 'member' || member.STATUS !== 'pending')) {
      v2Unprocessable('只能处理待审批的普通成员');
    }

    let sql: string;
    let args: oracledb.BindParameters = binds;
    let details: string | null = null;
    if (action.kind === 'change_role') {
      if (groupMemberRank(action.role) >= rank) v2Unprocessable(permission);
      if (action.role === member.ROLE) {
        await connection.rollback();
        return null;
      }
      sql = groupMemberRoleSql;
      args = { ...groupBind, user_id: target, role: action.role };
      details = JSON.stringify({ old_role: member.ROLE, new_role: action.role });
    } else if (action.kind === 'mute_member') {
      sql = groupMuteSql;
      args = { ...groupBind, user_id: target, hours: action.hours, reason: action.reason };
      details = JSON.stringify({ duration_hours: action.hours, reason: action.reason ?? '' });
    } else if (action.kind === 'unmute_member') {
      if (member.STATUS === 'active') {
        await connection.rollback();
        return null;
      }
      sql = groupUnmuteSql;
    } else if (action.kind === 'remove_member') {
      sql = groupRemoveMemberSql;
    } else {
      sql = action.kind === 'approve_member' ? groupApproveSql : groupRejectSql;
    }
    if (await v2Execute(connection, sql, args, false) !== 1) v2ServerError();
    let expiry: string | null = null;
    if (action.kind === 'mute_member') {
      const row = await v2One(connection, groupMuteUntilSql, { ...groupBind, user_id: target });
      expiry = v2StringOrNull(row?.MUTE_UNTIL);
      if (!expiry) v2ServerError();
    }
    if (await v2Execute(connection, groupAdmissionAuditSql, {
      ...groupBind, actor_id: viewer, target_user_id: userId, action: action.kind, details
    }, false) !== 1) v2ServerError();
    await connection.commit();
    return expiry;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2ApproveMember(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupMemberStatusData>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  // The route directory is shared with user-ID operations, but approval uses a membership ID.
  const memberId = groupAdmissionId(event, 'user_id', '成员 ID 参数错误');
  let body: unknown;
  try {
    const raw = await readRawBody(event);
    if (!raw || Buffer.byteLength(raw) > (1 << 20)) v2BadRequest('approved 参数错误');
    body = JSON.parse(raw);
  } catch {
    v2BadRequest('approved 参数错误');
  }
  if (!body || typeof body !== 'object' || Array.isArray(body) || !('approved' in body) || typeof body.approved !== 'boolean') {
    v2BadRequest('approved 参数错误');
  }
  const approved = body.approved;
  await changeGroupAdmission(connection, userId, groupId, memberId, { kind: approved ? 'approve_member' : 'reject_member' });
  return v2Ok({ member_id: memberId, status: approved ? 'active' : 'rejected' },
    approved ? 'member approved' : 'member rejected');
}

export async function v2RemoveMember(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<null>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const target = groupAdmissionId(event, 'user_id', '成员 ID 参数错误');
  await changeGroupAdmission(connection, userId, groupId, target, { kind: 'remove_member' });
  return v2Null('member removed');
}

function groupModerationContext(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return {
    viewer: v2Auth(event).userId,
    group: groupAdmissionId(event, 'id', 'id 参数错误'),
    target: groupAdmissionId(event, 'user_id', '成员 ID 参数错误')
  };
}

async function groupModerationBody(event: H3Event, error = '请求体必须是 JSON 对象', allowEmpty = false): Promise<Record<string, unknown>> {
  let body: unknown;
  try {
    const raw = await readRawBody(event);
    if (allowEmpty && (!raw || /^[\t\n\r ]*$/.test(raw)) && Buffer.byteLength(raw ?? '') <= (1 << 20)) return {};
    if (!raw || Buffer.byteLength(raw) > (1 << 20)) v2BadRequest(error);
    body = JSON.parse(raw);
  } catch {
    v2BadRequest(error);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) v2BadRequest(error);
  return body as Record<string, unknown>;
}

export async function v2ChangeMemberRole(event: H3Event, connection: oracledb.Connection): Promise<V2Response<V2GroupMemberStatusData>> {
  const { viewer, group, target } = groupModerationContext(event);
  const { role } = await groupModerationBody(event);
  if (role !== 'admin' && role !== 'moderator' && role !== 'member') v2BadRequest('role 参数错误');
  await changeGroupAdmission(connection, viewer, group, target, { kind: 'change_role', role });
  return v2Ok({ user_id: target, role }, 'role updated');
}

export async function v2MuteMember(event: H3Event, connection: oracledb.Connection): Promise<V2Response<V2GroupMemberStatusData>> {
  const { viewer, group, target } = groupModerationContext(event);
  const { duration_hours: duration, reason } = await groupModerationBody(event);
  const hours = duration === undefined ? 24 : duration;
  if (typeof hours !== 'number' || !Number.isInteger(hours) || hours < 1 || hours > 8760) v2BadRequest('duration_hours 参数错误');
  if (reason != null && (typeof reason !== 'string' || Buffer.byteLength(reason) > 200)) v2BadRequest('reason 参数错误');
  const mute_until = await changeGroupAdmission(connection, viewer, group, target, { kind: 'mute_member', hours, reason: reason ?? null });
  return v2Ok({ user_id: target, status: 'muted', mute_until }, 'member muted');
}

export async function v2UnmuteMember(event: H3Event, connection: oracledb.Connection): Promise<V2Response<V2GroupMemberStatusData>> {
  const { viewer, group, target } = groupModerationContext(event);
  await changeGroupAdmission(connection, viewer, group, target, { kind: 'unmute_member' });
  return v2Ok({ user_id: target, status: 'active' }, 'member unmuted');
}

const demoteGroupOwnerSql = `UPDATE n_group_members SET role='admin' WHERE group_id=:group_id AND user_id=:user_id AND role='owner' AND status='active'`;
const promoteGroupOwnerSql = `UPDATE n_group_members SET role='owner' WHERE group_id=:group_id AND user_id=:user_id AND role<>'owner' AND status='active'`;
const transferGroupOwnershipSql = `UPDATE n_groups SET owner_id=:new_owner_id WHERE group_id=:group_id AND owner_id=:old_owner_id AND is_active=1 AND is_deleted=0`;

export async function v2TransferOwnership(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<{ group_id: number; owner_id: number }>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const actor = v2Auth(event).userId;
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const { new_owner_id: target } = await groupModerationBody(event, 'new_owner_id 参数错误');
  if (typeof target !== 'number' || !Number.isSafeInteger(target) || target < 1) v2BadRequest('new_owner_id 参数错误');

  const groupBind = { group_id: groupId };
  const oldMember = { ...groupBind, user_id: actor };
  const newMember = { ...groupBind, user_id: target };
  try {
    const group = await v2One(connection, groupMembershipLockSql, groupBind);
    if (!group || v2Number(group.IS_ACTIVE) !== 1 || v2Number(group.IS_DELETED) !== 0) v2NotFound('群组不存在');
    if (v2Number(group.OWNER_ID) !== actor) v2Unprocessable('只有群主可以转让群组');
    const owner = await v2One(connection, groupMembershipReadSql, oldMember);
    if (owner?.ROLE !== 'owner' || owner.STATUS !== 'active') v2Unprocessable('只有群主可以转让群组');
    if (actor === target) v2Unprocessable('不能转让给自己');
    const successor = await v2One(connection, groupMembershipReadSql, newMember);
    if (!successor) v2NotFound('成员不存在');
    if (successor.STATUS !== 'active' || successor.ROLE === 'owner') v2Unprocessable('目标用户不是可接任的活跃成员');

    if (await v2Execute(connection, demoteGroupOwnerSql, oldMember, false) !== 1 ||
        await v2Execute(connection, promoteGroupOwnerSql, newMember, false) !== 1 ||
        await v2Execute(connection, transferGroupOwnershipSql, { ...groupBind, old_owner_id: actor, new_owner_id: target }, false) !== 1 ||
        await v2Execute(connection, groupAdmissionAuditSql, {
          ...groupBind, actor_id: actor, target_user_id: target, action: 'transfer_ownership',
          details: JSON.stringify({ from: actor, to: target })
        }, false) !== 1) v2ServerError();
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  return v2Ok({ group_id: groupId, owner_id: target }, 'ownership transferred');
}

const groupContentSql = `SELECT group_id FROM n_groups
WHERE group_id=:group_id AND is_active=1 AND is_deleted=0`;
const groupContentPostSql = `SELECT author_id FROM n_group_posts
WHERE group_id=:group_id AND post_id=:post_id AND is_deleted=0`;
const groupContentCommentSql = `SELECT author_id FROM n_group_comments
WHERE post_id=:post_id AND comment_id=:comment_id AND is_deleted=0`;

async function requireGroupContentAccess(
  connection: oracledb.Connection,
  userId: number,
  groupId: number
): Promise<void> {
  const allowed = await v2One(connection,
    'SELECT fn_can_view_group(:user_id, :group_id) AS allowed FROM dual',
    { user_id: userId, group_id: groupId });
  if (!v2Boolean(allowed?.ALLOWED)) v2NotFound('群组不存在');
}

async function requireGroupContentPost(
  connection: oracledb.Connection,
  groupId: number,
  postId: number
): Promise<V2DbRecord> {
  const post = await v2One(connection, groupContentPostSql, { group_id: groupId, post_id: postId });
  if (!post) v2NotFound('群组帖子不存在');
  return post;
}

async function requireGroupContentComment(
  connection: oracledb.Connection,
  postId: number,
  commentId: number
): Promise<V2DbRecord> {
  const comment = await v2One(connection, groupContentCommentSql, { post_id: postId, comment_id: commentId });
  if (!comment) v2NotFound('群组评论不存在');
  return comment;
}

const groupAuthorVisibleSql = `SELECT 1 AS visible FROM n_users u
WHERE u.user_id=:author_id AND u.is_active=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=:viewer_id AND b.target_user_id=u.user_id)
       OR (b.target_user_id=:viewer_id AND b.user_id=u.user_id))`;

async function requireVisibleGroupAuthor(
  connection: oracledb.Connection, viewerId: number, authorId: number, missing: string
) {
  const row = await v2One(connection, groupAuthorVisibleSql, {
    viewer_id: viewerId, author_id: authorId
  });
  if (!row) v2NotFound(missing);
}

async function withGroupContentWrite<T>(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  write: () => Promise<T>
): Promise<T> {
  try {
    const group = await v2One(connection, `${groupContentSql} FOR UPDATE`, { group_id: groupId });
    if (!group) v2NotFound('群组不存在');
    await requireGroupContentAccess(connection, userId, groupId);
    const result = await write();
    await connection.commit();
    return result;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

const groupContentPostsSql = `WITH allowed_group AS (
  SELECT g.group_id
  FROM n_groups g
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
    AND (g.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=g.group_id AND m.user_id=:viewer_id AND m.status='active'))
), ranked AS (
  SELECT p.post_id,p.group_id,p.author_id,p.content,p.media_urls,p.is_pinned,p.is_announcement,p.likes_count,p.comments_count,p.views_count,p.created_at,p.updated_at,
    CASE WHEN EXISTS (SELECT 1 FROM n_group_post_likes l
      WHERE l.post_id=p.post_id AND l.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked_by_me,
    ROW_NUMBER() OVER (ORDER BY CASE WHEN p.is_pinned=1 THEN 2 WHEN p.is_announcement=1 THEN 1 ELSE 0 END DESC,
      p.created_at DESC,p.post_id DESC) AS rn
  FROM allowed_group g
  JOIN n_group_posts p ON p.group_id=g.group_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  WHERE (:post_id=0 OR p.post_id=:post_id)
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=p.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=p.author_id))
    AND (:post_type='all' OR :post_type='pinned' AND p.is_pinned=1
      OR :post_type='announcement' AND p.is_announcement=1)
)
SELECT (SELECT COUNT(*) FROM allowed_group) AS group_allowed,t.total,
  r.post_id,r.group_id,r.author_id,r.content,r.media_urls,r.is_pinned,r.is_announcement,r.likes_count,r.comments_count,r.views_count,r.created_at,r.updated_at,r.is_liked_by_me
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn`;
const groupContentCommentsSql = `WITH allowed_group AS (
  SELECT g.group_id
  FROM n_groups g
  WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
    AND (g.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=g.group_id AND m.user_id=:viewer_id AND m.status='active'))
), allowed_post AS (
  SELECT p.post_id,p.group_id
  FROM allowed_group g
  JOIN n_group_posts p ON p.group_id=g.group_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  WHERE p.post_id=:post_id
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=p.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=p.author_id))
), ranked AS (
  SELECT c.comment_id,c.post_id,c.author_id,c.parent_comment_id,
    CASE WHEN EXISTS (SELECT 1 FROM n_users reply_author
      WHERE reply_author.user_id=c.reply_to_user_id AND reply_author.is_active=1
        AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
          WHERE (b.user_id=:viewer_id AND b.target_user_id=reply_author.user_id)
             OR (b.target_user_id=:viewer_id AND b.user_id=reply_author.user_id)))
      THEN c.reply_to_user_id END AS reply_to_user_id,
    c.content,c.likes_count,c.created_at,c.updated_at,
    CASE WHEN EXISTS (SELECT 1 FROM n_group_comment_likes l
      WHERE l.comment_id=c.comment_id AND l.user_id=:viewer_id) THEN 1 ELSE 0 END AS is_liked_by_me,
    CASE WHEN c.author_id=:viewer_id OR EXISTS (SELECT 1 FROM n_group_members m
      WHERE m.group_id=p.group_id AND m.user_id=:viewer_id AND m.status='active'
        AND m.role IN ('owner','admin','moderator')) THEN 1 ELSE 0 END AS can_delete_by_me,
    ROW_NUMBER() OVER (ORDER BY
      CASE WHEN :comment_sort='popular' THEN c.likes_count END DESC,
      CASE WHEN :comment_sort='oldest' THEN c.created_at END ASC,
      CASE WHEN :comment_sort='oldest' THEN c.comment_id END ASC,
      c.created_at DESC,c.comment_id DESC) AS rn
  FROM allowed_post p
  JOIN n_group_comments c ON c.post_id=p.post_id AND c.is_deleted=0
  JOIN n_users comment_author ON comment_author.user_id=c.author_id AND comment_author.is_active=1
  WHERE (:target_comment_id=0 OR c.comment_id=:target_comment_id)
    AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
      WHERE (b.user_id=:viewer_id AND b.target_user_id=c.author_id)
         OR (b.target_user_id=:viewer_id AND b.user_id=c.author_id))
)
SELECT (SELECT COUNT(*) FROM allowed_group) AS group_allowed,
  (SELECT COUNT(*) FROM allowed_post) AS post_allowed,t.total,
  r.comment_id,r.post_id,r.author_id,r.parent_comment_id,r.reply_to_user_id,r.content,r.likes_count,r.created_at,r.updated_at,r.is_liked_by_me,r.can_delete_by_me
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn`;

async function v2MapGroupPost(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2GroupPost> {
  const postId = v2Number(row.POST_ID);
  return {
    post_id: postId,
    group_id: v2Number(row.GROUP_ID),
    author: await v2RequirePublicUser(
      connection,
      viewerId,
      v2Number(row.AUTHOR_ID)
    ),
    content: v2String(row.CONTENT),
    media_urls: v2MediaUrlArray(row.MEDIA_URLS),
    is_pinned: v2Boolean(row.IS_PINNED),
    is_announcement: v2Boolean(row.IS_ANNOUNCEMENT),
    likes_count: v2Number(row.LIKES_COUNT),
    comments_count: v2Number(row.COMMENTS_COUNT),
    views_count: v2Number(row.VIEWS_COUNT),
    is_liked_by_me: v2Boolean(row.IS_LIKED_BY_ME),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2GroupPosts(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupPost[]>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const page = v2Page(event);
  const type = v2QueryString(event, 'type') || 'all';
  if (!['all', 'pinned', 'announcement'].includes(type)) v2BadRequest('type 参数错误');
  const result = await v2Rows(connection, groupContentPostsSql, {
    viewer_id: auth.userId, group_id: groupId, post_id: 0, post_type: type, start_row: page.start, end_row: page.end
  });
  if (!v2Boolean(result[0]?.GROUP_ALLOWED)) v2NotFound('群组不存在');
  const total = v2Number(result[0]?.TOTAL);
  const rows = result.filter(row => row.POST_ID != null);
  const posts = await Promise.all(
    rows.map(row =>
      v2MapGroupPost(connection, auth.userId, row)
    )
  );
  return v2Ok(
    posts,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateGroupPost(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupPost>> {
  await v2EnsureGroupFeatureSchema(connection);
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const body = await groupModerationBody(event);
  const content = typeof body.content === 'string' ? body.content.trim() : '';
  if (!content || Buffer.byteLength(content) > 4000) v2BadRequest('content 参数错误');
  const announcement = body.is_announcement === undefined ? false : body.is_announcement;
  if (typeof announcement !== 'boolean') v2BadRequest('is_announcement 参数错误');
  const media = body.media_urls === undefined ? [] : body.media_urls;
  if (!Array.isArray(media) || !media.every(url => typeof url === 'string' && !url.includes(','))) {
    v2BadRequest('media_urls 参数错误');
  }
  const mediaUrls = (media as string[]).map(url => url.trim()).filter(Boolean);
  if (Buffer.byteLength(mediaUrls.join(',')) > 2000) v2BadRequest('media_urls 参数错误');
  const created = await withGroupContentWrite(connection, auth.userId, groupId, async () => {
    const allowed = await v2One(
      connection,
      'SELECT fn_can_post_in_group(:user_id, :group_id) AS allowed FROM dual',
      { user_id: auth.userId, group_id: groupId }
    );
    if (!v2Boolean(allowed?.ALLOWED))
      v2Unprocessable('无权发帖');
    if (announcement && !(await v2GroupPermission(connection, auth.userId, groupId, 'moderator'))) {
      v2Unprocessable('无权发布公告');
    }
    await requirePublishAccess(connection, auth.userId);
    const lockedUrls = await v2LockGroupMediaUrls(connection, mediaUrls, '群组附件不存在或已删除');
    const storedUrls = lockedUrls.join(',');
    if (lockedUrls.some(url => url.includes(',')) || Buffer.byteLength(storedUrls) > 2000)
      v2BadRequest('media_urls 参数错误');
    const postId = await v2NextId(
      connection,
      'seq_group_post_id'
    );
    const inserted = await v2Execute(
      connection,
      `
      INSERT INTO n_group_posts (
        post_id,
        group_id,
        author_id,
        content,
        media_urls,
        is_announcement
      ) VALUES (
        :post_id,
        :group_id,
        :author_id,
        :content,
        :media_urls,
        :is_announcement
      )
      `,
      {
        post_id: postId,
        group_id: groupId,
        author_id: auth.userId,
        content,
        media_urls: storedUrls || null,
        is_announcement: announcement ? 1 : 0
      },
      false
    );
    if (inserted !== 1) v2ServerError();
    const post = await v2RequireGroupPost(connection, auth.userId, groupId, postId).catch(() => v2ServerError());
    return { postId, post };
  });
  await v2NotifyGroupPostCreated(
    connection,
    groupId,
    created.postId,
    auth.userId,
    content
  ).catch(() => logWarn('group-post:notification-failed', { groupId, postId: created.postId }));
  return v2Ok(created.post, 'group post created');
}

export async function v2RequireGroupPost(
  connection: oracledb.Connection,
  viewerId: number,
  groupId: number,
  postId: number
): Promise<V2GroupPost> {
  const row = await v2One(connection, groupContentPostsSql, {
    viewer_id: viewerId, group_id: groupId, post_id: postId, post_type: 'all', start_row: 1, end_row: 1
  });
  if (!v2Boolean(row?.GROUP_ALLOWED)) v2NotFound('群组不存在');
  if (!row || row.POST_ID == null) v2NotFound('群组帖子不存在');
  return await v2MapGroupPost(connection, viewerId, row);
}

export async function v2GetGroupPost(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupPost>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  return v2Ok(
    await v2RequireGroupPost(
      connection,
      auth.userId,
      groupId,
      postId
    )
  );
}

export async function v2DeleteGroupPost(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<null>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  const { reason = null } = await groupModerationBody(event, undefined, true);
  if (reason !== null && (typeof reason !== 'string' || Buffer.byteLength(reason) > 200)) v2BadRequest('reason 参数错误');
  return withGroupContentWrite(connection, auth.userId, groupId, async () => {
    const post = await requireGroupContentPost(connection, groupId, postId);
    if (
      v2Number(post.AUTHOR_ID) !== auth.userId &&
      !(await v2GroupPermission(
        connection,
        auth.userId,
        groupId,
        'moderator'
      ))
    ) {
      v2Unprocessable('无权删除帖子');
    }
    const updated = await v2Execute(
      connection,
      `
      UPDATE n_group_posts
      SET is_deleted = 1,
          deleted_by = :deleted_by,
          delete_reason = :reason
      WHERE post_id = :post_id AND group_id = :group_id AND is_deleted = 0
      `,
      {
        deleted_by: auth.userId,
        reason: reason || null,
        post_id: postId,
        group_id: groupId
      },
      false
    );
    if (updated !== 1) v2ServerError();
    return v2Null('group post deleted');
  });
}

export async function v2SetGroupPostPin(
  event: H3Event,
  connection: oracledb.Connection
): Promise<
  V2Response<{ post_id: number; is_pinned: boolean }>
> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  const { is_pinned: isPinned } = await groupModerationBody(event);
  if (typeof isPinned !== 'boolean') v2BadRequest('is_pinned 参数错误');
  return withGroupContentWrite(connection, auth.userId, groupId, async () => {
    const post = await requireGroupContentPost(connection, groupId, postId);
    const author = v2Number(post.AUTHOR_ID);
    if (isPinned) await requireVisibleGroupAuthor(connection, auth.userId, author, '群组帖子不存在');
    if (
      !(await v2GroupPermission(
        connection,
        auth.userId,
        groupId,
        'moderator'
      ))
    ) {
      v2Unprocessable('无权置顶帖子');
    }
    const updated = await v2Execute(
      connection,
      `
      UPDATE n_group_posts
      SET is_pinned = :is_pinned
      WHERE post_id = :post_id
        AND group_id = :group_id AND is_deleted = 0
      `,
      {
        is_pinned: isPinned ? 1 : 0,
        post_id: postId,
        group_id: groupId
      },
      false
    );
    if (updated !== 1) v2ServerError();
    if (isPinned) await requireVisibleGroupAuthor(connection, auth.userId, author, '群组帖子不存在');
    return v2Ok(
      { post_id: postId, is_pinned: isPinned },
      'pin status updated'
    );
  });
}

export async function v2LikeGroupPost(
  event: H3Event,
  connection: oracledb.Connection,
  liked: boolean
): Promise<
  V2Response<{
    post_id: number;
    is_liked: boolean;
    likes_count: number;
  }>
> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  return withGroupContentWrite(connection, auth.userId, groupId, async () => {
    const post = await requireGroupContentPost(connection, groupId, postId);
    const author = v2Number(post.AUTHOR_ID);
    await requireVisibleGroupAuthor(connection, auth.userId, author, '群组帖子不存在');
    if (liked) {
      await v2Execute(
        connection,
        `
        INSERT INTO n_group_post_likes (post_id, user_id)
        SELECT :post_id, :user_id
        FROM dual
        WHERE NOT EXISTS (
          SELECT 1 FROM n_group_post_likes
          WHERE post_id = :post_id AND user_id = :user_id
        )
        `,
        { post_id: postId, user_id: auth.userId },
        false
      );
    } else {
      await v2Execute(
        connection,
        `
        DELETE FROM n_group_post_likes
        WHERE post_id = :post_id
          AND user_id = :user_id
        `,
        { post_id: postId, user_id: auth.userId },
        false
      );
    }
    const row = await v2One(
      connection,
      `
      SELECT likes_count
      FROM n_group_posts
      WHERE post_id = :post_id
      `,
      { post_id: postId }
    );
    if (!row) v2ServerError();
    await requireVisibleGroupAuthor(connection, auth.userId, author, '群组帖子不存在');
    return v2Ok({
      post_id: postId,
      is_liked: liked,
      likes_count: v2Number(row.LIKES_COUNT)
    });
  });
}

async function v2MapGroupComment(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2GroupComment> {
  const replyToId = v2Number(row.REPLY_TO_USER_ID);
  const canDelete =
    row.CAN_DELETE_BY_ME === undefined
      ? v2Number(row.AUTHOR_ID) === viewerId ||
        (await v2GroupPermission(
          connection,
          viewerId,
          v2Number(row.GROUP_ID),
          'moderator'
        ))
      : v2Boolean(row.CAN_DELETE_BY_ME);
  return {
    comment_id: v2Number(row.COMMENT_ID),
    post_id: v2Number(row.POST_ID),
    author: await v2RequirePublicUser(
      connection,
      viewerId,
      v2Number(row.AUTHOR_ID)
    ),
    parent_comment_id:
      row.PARENT_COMMENT_ID === null
        ? null
        : v2Number(row.PARENT_COMMENT_ID),
    reply_to_user: replyToId
      ? await v2RequirePublicUser(
          connection,
          viewerId,
          replyToId
        )
      : null,
    content: v2String(row.CONTENT),
    likes_count: v2Number(row.LIKES_COUNT),
    is_liked_by_me: v2Boolean(row.IS_LIKED_BY_ME),
    can_delete_by_me: canDelete,
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2GroupComments(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupComment[]>> {
  await v2EnsureGroupFeatureSchema(connection);
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  const rawCommentId = getQuery(event).comment_id;
  if (rawCommentId !== undefined && (typeof rawCommentId !== 'string' ||
      !/^[1-9][0-9]{0,15}$/.test(rawCommentId) || rawCommentId.trim() !== rawCommentId ||
      !Number.isSafeInteger(Number(rawCommentId)))) {
    v2BadRequest('comment_id 参数错误');
  }
  const commentId = rawCommentId === undefined ? 0 : Number(rawCommentId);
  const page = commentId === 0 ? v2Page(event) : {page:1,page_size:1,start:1,end:1};
  const sort = v2QueryString(event, 'sort') || 'newest';
  if (!['newest', 'oldest', 'popular'].includes(sort)) v2BadRequest('sort 参数错误');
  const result = await v2Rows(connection, groupContentCommentsSql, {
    viewer_id: auth.userId, group_id: groupId, post_id: postId, target_comment_id: commentId,
    comment_sort: sort, start_row: page.start, end_row: page.end
  });
  if (!v2Boolean(result[0]?.GROUP_ALLOWED)) v2NotFound('群组不存在');
  if (!v2Boolean(result[0]?.POST_ALLOWED)) v2NotFound('群组帖子不存在');
  const total = v2Number(result[0]?.TOTAL);
  const rows = result.filter(row => row.COMMENT_ID != null);
  const comments = await Promise.all(
    rows.map(row =>
      v2MapGroupComment(connection, auth.userId, row)
    )
  );
  return v2Ok(
    comments,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateGroupComment(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupComment>> {
  await v2EnsureGroupFeatureSchema(connection);
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  const body = await groupModerationBody(event);
  const content = typeof body.content === 'string' ? body.content.trim() : '';
  if (!content || Buffer.byteLength(content) > 1000) v2BadRequest('content 参数错误');
  const parentId = body.parent_comment_id == null ? null : groupInviteInteger(body.parent_comment_id, Number.MAX_SAFE_INTEGER, 'parent_comment_id');
  const replyId = body.reply_to_user_id == null ? null : groupInviteInteger(body.reply_to_user_id, Number.MAX_SAFE_INTEGER, 'reply_to_user_id');
  const created = await withGroupContentWrite(connection, auth.userId, groupId, async () => {
    const post = await requireGroupContentPost(connection, groupId, postId);
    const postAuthor = v2Number(post.AUTHOR_ID);
    await requireVisibleGroupAuthor(connection, auth.userId, postAuthor, '群组帖子不存在');
    if (!(await v2GroupPermission(connection, auth.userId, groupId, 'member'))) v2Unprocessable('只有群组成员可以评论');
    const target = parentId === null
      ? postAuthor
      : v2Number((await requireGroupContentComment(connection, postId, parentId)).AUTHOR_ID);
    if (parentId !== null && target !== postAuthor) {
      await requireVisibleGroupAuthor(connection, auth.userId, target, '群组评论不存在');
    }
    if (replyId !== null && replyId !== target) v2Unprocessable('回复用户与目标不匹配');
    await requirePublishAccess(connection, auth.userId);
    const commentId = await v2NextId(
      connection,
      'seq_group_comment_id'
    );
    if (!Number.isSafeInteger(commentId) || commentId < 1) v2ServerError();
    const inserted = await v2Execute(
      connection,
      `
      INSERT INTO n_group_comments (
        comment_id,
        post_id,
        author_id,
        parent_comment_id,
        reply_to_user_id,
        content
      ) VALUES (
        :comment_id,
        :post_id,
        :author_id,
        :parent_comment_id,
        :reply_to_user_id,
        :content
      )
      `,
      {
        comment_id: commentId,
        post_id: postId,
        author_id: auth.userId,
        parent_comment_id: parentId,
        reply_to_user_id: parentId === null ? replyId : target,
        content
      },
      false
    );
    if (inserted !== 1) v2ServerError();
    const row = await v2One(
      connection,
      `
      SELECT c.*, 0 AS is_liked_by_me, 1 AS can_delete_by_me
      FROM n_group_comments c
      WHERE post_id = :post_id AND comment_id = :comment_id AND is_deleted = 0
      `,
      { post_id: postId, comment_id: commentId }
    );
    if (!row) v2ServerError();
    const comment = await v2MapGroupComment(connection, auth.userId, row).catch(() => null);
    await requireVisibleGroupAuthor(connection, auth.userId, postAuthor, '群组帖子不存在');
    if (parentId !== null && target !== postAuthor) {
      await requireVisibleGroupAuthor(connection, auth.userId, target, '群组评论不存在');
    }
    if (!comment) v2ServerError();
    return { commentId, comment };
  });
  await v2NotifyGroupCommentCreated(connection, {
    groupId,
    postId,
    commentId: created.commentId,
    actorId: auth.userId,
    content,
    parentCommentId: parentId
  }).catch(() => logWarn('group-comment:notification-failed', { groupId, postId, commentId: created.commentId }));
  return v2Ok(created.comment, 'group comment created');
}

export async function v2DeleteGroupComment(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<null>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  const commentId = groupAdmissionId(event, 'comment_id', 'comment_id 参数错误');
  return withGroupContentWrite(connection, auth.userId, groupId, async () => {
    await requireGroupContentPost(connection, groupId, postId);
    const comment = await requireGroupContentComment(connection, postId, commentId);
    if (
      v2Number(comment.AUTHOR_ID) !== auth.userId &&
      !(await v2GroupPermission(
        connection,
        auth.userId,
        groupId,
        'moderator'
      ))
    ) {
      v2Unprocessable('无权删除评论');
    }
    const updated = await v2Execute(
      connection,
      `
      UPDATE n_group_comments
      SET is_deleted = 1,
          deleted_by = :deleted_by
      WHERE comment_id = :comment_id AND post_id = :post_id AND is_deleted = 0
      `,
      { deleted_by: auth.userId, comment_id: commentId, post_id: postId },
      false
    );
    if (updated !== 1) v2ServerError();
    return v2Null('group comment deleted');
  });
}

export async function v2LikeGroupComment(
  event: H3Event,
  connection: oracledb.Connection,
  liked: boolean
): Promise<
  V2Response<{
    comment_id: number;
    is_liked: boolean;
    likes_count: number;
  }>
> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const auth = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const postId = groupAdmissionId(event, 'post_id', 'post_id 参数错误');
  const commentId = groupAdmissionId(event, 'comment_id', 'comment_id 参数错误');
  return withGroupContentWrite(connection, auth.userId, groupId, async () => {
    const post = await requireGroupContentPost(connection, groupId, postId);
    const postAuthor = v2Number(post.AUTHOR_ID);
    await requireVisibleGroupAuthor(connection, auth.userId, postAuthor, '群组帖子不存在');
    const comment = await requireGroupContentComment(connection, postId, commentId);
    const author = v2Number(comment.AUTHOR_ID);
    if (author !== postAuthor) {
      await requireVisibleGroupAuthor(connection, auth.userId, author, '群组评论不存在');
    }
    if (liked) {
      await v2Execute(
        connection,
        `
        INSERT INTO n_group_comment_likes (comment_id, user_id)
        SELECT :comment_id, :user_id
        FROM dual
        WHERE NOT EXISTS (
          SELECT 1 FROM n_group_comment_likes
          WHERE comment_id = :comment_id AND user_id = :user_id
        )
        `,
        { comment_id: commentId, user_id: auth.userId },
        false
      );
    } else {
      await v2Execute(
        connection,
        `
        DELETE FROM n_group_comment_likes
        WHERE comment_id = :comment_id
          AND user_id = :user_id
        `,
        { comment_id: commentId, user_id: auth.userId },
        false
      );
    }
    const row = await v2One(
      connection,
      `
      SELECT likes_count
      FROM n_group_comments
      WHERE comment_id = :comment_id
      `,
      { comment_id: commentId }
    );
    if (!row) v2ServerError();
    await requireVisibleGroupAuthor(connection, auth.userId, postAuthor, '群组帖子不存在');
    if (author !== postAuthor) {
      await requireVisibleGroupAuthor(connection, auth.userId, author, '群组评论不存在');
    }
    return v2Ok({
      comment_id: commentId,
      is_liked: liked,
      likes_count: v2Number(row.LIKES_COUNT)
    });
  });
}

const groupInviteInsertSql = `INSERT INTO n_group_invites (invite_id,group_id,inviter_id,invitee_id,invite_code,max_uses,message,expires_at)
VALUES (:invite_id,:group_id,:inviter_id,:invitee_id,:invite_code,:max_uses,:message,SYSTIMESTAMP+NUMTODSINTERVAL(:expire_hours,'HOUR'))`;
const groupInviteExpirySql = `SELECT TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(expires_at,TO_CHAR(SYSTIMESTAMP,'TZH:TZM'))),'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS expires_at FROM n_group_invites WHERE invite_id=:invite_id`;
const groupInviteTargetSql = `SELECT user_id FROM n_users WHERE user_id=:target AND is_active=1 AND status='active'`;
const groupInviteNamesSql = `SELECT g.name,COALESCE(u.display_name,u.username) AS inviter_name FROM n_groups g JOIN n_users u ON u.user_id=:inviter_id WHERE g.group_id=:group_id`;

function groupInviteInteger(input: unknown, max: number, field: string): number {
  if (typeof input !== 'number' || !Number.isSafeInteger(input) || input < 1 || input > max) {
    v2BadRequest(`${field} 参数错误`);
  }
  return input;
}

function limitGroupNoticeTitle(text: string): string {
  let result = '';
  for (const character of text) {
    if (Buffer.byteLength(result + character) > 200) break;
    result += character;
  }
  return result;
}

export async function v2CreateGroupInvite(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2CreateGroupInviteData>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const body = await groupModerationBody(event);
  const target = body.invitee_id == null ? null : groupInviteInteger(body.invitee_id, Number.MAX_SAFE_INTEGER, 'invitee_id');
  const maxUses = body.max_uses === undefined ? 1 : groupInviteInteger(body.max_uses, 99999, 'max_uses');
  const hours = body.expire_hours === undefined ? 168 : groupInviteInteger(body.expire_hours, 8760, 'expire_hours');
  const message = body.message ?? null;
  if (message !== null && (typeof message !== 'string' || Buffer.byteLength(message) > 200)) v2BadRequest('message 参数错误');
  await v2EnsureGroupFeatureSchema(connection);

  let notification: Awaited<ReturnType<typeof v2StoreNotification>> = null;
  let result: V2CreateGroupInviteData;
  try {
    const group = await v2One(connection, groupMembershipLockSql, { group_id: groupId });
    if (!group || v2Number(group.IS_ACTIVE) !== 1 || v2Number(group.IS_DELETED) !== 0) v2NotFound('群组不存在');
    const actor = await v2One(connection, groupMembershipReadSql, { group_id: groupId, user_id: userId });
    if (actor?.STATUS !== 'active' || !groupMemberRank(actor.ROLE)) v2Unprocessable('无权创建邀请');

    if (target !== null) {
      if (target === userId) v2Unprocessable('不能邀请自己');
      if (!await v2One(connection, groupInviteTargetSql, { target })) v2NotFound('被邀请用户不存在');
      if (await v2One(connection, groupMembershipReadSql, { group_id: groupId, user_id: target })) {
        v2Unprocessable('被邀请用户已有群组成员记录');
      }
    }
    const id = await v2NextId(connection, 'seq_group_invite_id');
    if (!Number.isSafeInteger(id) || id < 1) v2ServerError();
    const code = target === null ? randomBytes(16).toString('hex').toUpperCase() : null;
    if (await v2Execute(connection, groupInviteInsertSql, {
      invite_id: id, group_id: groupId, inviter_id: userId, invitee_id: target,
      invite_code: code, max_uses: target === null ? maxUses : 1, message, expire_hours: hours
    }, false) !== 1) v2ServerError();
    const row = await v2One(connection, groupInviteExpirySql, { invite_id: id });
    const expires = v2StringOrNull(row?.EXPIRES_AT);
    if (!expires) v2ServerError();

    if (target !== null && await v2GroupNotificationsEnabled(connection, target, groupId)) {
      const names = await v2One(connection, groupInviteNamesSql, { group_id: groupId, inviter_id: userId });
      if (!names) v2ServerError();
      notification = await v2StoreNotification(connection, {
        userId: target, actorId: userId, type: 'group_invite',
        title: limitGroupNoticeTitle(`${v2String(names.INVITER_NAME, '有人')} 邀请你加入 ${v2String(names.NAME, '群组')}`),
        message: message || '你收到了一条新的群组邀请。', resourceType: 'group_invite', resourceId: id,
        priority: 'normal', metadata: { group_id: groupId, invite_id: id, event: 'group_invite_created' }
      }, false);
    }
    result = { invite_id: id, invite_code: code, invite_url: code ? `/groups/invite/${code}` : null, expires_at: expires };
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  if (notification) {
    try { await v2DeliverStoredNotification(connection, notification); }
    catch { console.warn('group invitation realtime delivery unavailable'); }
  }
  return v2Ok(result, 'invite created');
}

async function v2MapInvite(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2GroupInvite> {
  const inviteeId = v2Number(row.INVITEE_ID);
  const groupId = v2Number(row.GROUP_ID);
  return {
    invite_id: v2Number(row.INVITE_ID),
    invite_code: v2StringOrNull(row.INVITE_CODE),
    status: v2String(row.STATUS),
    message: v2StringOrNull(row.MESSAGE),
    max_uses:
      row.MAX_USES === null ? null : v2Number(row.MAX_USES),
    used_count: v2Number(row.USED_COUNT),
    expires_at: v2DateString(row.EXPIRES_AT),
    created_at: v2DateString(row.CREATED_AT) || '',
    group: groupId
      ? {
          group_id: groupId,
          name: v2String(row.GROUP_NAME),
          slug: v2String(row.GROUP_SLUG),
          description: v2String(row.GROUP_DESCRIPTION),
          avatar_url: v2StringOrNull(row.GROUP_AVATAR_URL),
          privacy: v2String(
            row.GROUP_PRIVACY,
            'public'
          ) as V2GroupPrivacy,
          member_count: v2Number(row.GROUP_MEMBER_COUNT)
        }
      : null,
    inviter: await v2RequirePublicUser(
      connection,
      viewerId,
      v2Number(row.INVITER_ID)
    ),
    invitee: inviteeId
      ? await v2RequirePublicUser(
          connection,
          viewerId,
          inviteeId
        )
      : null,
    is_valid: v2Boolean(row.IS_VALID)
  };
}

const groupInviteListSql = `WITH invite_scope AS (
 SELECT g.group_id,g.description,
 CASE WHEN m.status='active' AND m.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END AS allowed
 FROM n_groups g LEFT JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:viewer_id
 WHERE g.group_id=:group_id AND g.is_active=1 AND g.is_deleted=0
), eligible AS (
 SELECT v.invite_id,v.invite_code,v.status,v.message,v.max_uses,v.used_count,v.expires_at,v.created_at,
 v.group_id,v.group_name,v.group_slug,s.description AS group_description,v.group_avatar_url,v.group_privacy,
 v.group_member_count,v.inviter_id,v.invitee_id,v.is_valid,
 ROW_NUMBER() OVER (ORDER BY v.created_at DESC,v.invite_id DESC) AS rn
 FROM invite_scope s JOIN v_group_invite_details v ON v.group_id=s.group_id
 WHERE s.allowed=1 AND (:status_filter IS NULL OR v.status=:status_filter)
)
SELECT s.allowed,t.total,e.invite_id,e.invite_code,e.status,e.message,e.max_uses,e.used_count,
 e.expires_at,e.created_at,e.group_id,e.group_name,e.group_slug,e.group_description,e.group_avatar_url,
 e.group_privacy,e.group_member_count,e.inviter_id,e.invitee_id,e.is_valid
FROM invite_scope s CROSS JOIN (SELECT COUNT(*) AS total FROM eligible) t
LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row
ORDER BY e.rn`;

export async function v2GroupInvites(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupInvite[]>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const page = v2Page(event);
  const { status } = getQuery(event);
  if (status !== undefined && status !== '' &&
      (typeof status !== 'string' || !['pending', 'accepted', 'rejected', 'expired'].includes(status))) {
    v2BadRequest('status 参数错误');
  }
  await v2EnsureGroupFeatureSchema(connection);
  const rows = await v2Rows(connection, groupInviteListSql, {
    viewer_id: userId, group_id: groupId, start_row: page.start, end_row: page.end,
    status_filter: typeof status === 'string' && status ? status : null
  });
  const scope = rows[0];
  if (!scope) v2NotFound('群组不存在');
  if (v2Number(scope.ALLOWED) !== 1) v2Unprocessable('无权查看群组邀请');
  const invites: V2GroupInvite[] = [];
  for (const row of rows) {
    if (row.INVITE_ID != null) invites.push(await v2MapInvite(connection, userId, row));
  }
  return v2Ok(invites, 'success', v2PageMeta(page.page, page.page_size, v2Number(scope.TOTAL)));
}

const groupInviteInboxSql = `WITH eligible AS (
 SELECT v.invite_id,v.invite_code,v.status,v.message,v.max_uses,v.used_count,v.expires_at,v.created_at,
 v.group_id,v.group_name,v.group_slug,g.description AS group_description,v.group_avatar_url,v.group_privacy,
 v.group_member_count,v.inviter_id,v.invitee_id,1 AS is_valid,
 ROW_NUMBER() OVER (ORDER BY v.created_at DESC,v.invite_id DESC) AS rn
 FROM v_group_invite_details v JOIN n_groups g ON g.group_id=v.group_id
 WHERE v.invitee_id=:viewer_id AND v.status='pending' AND g.is_active=1 AND g.is_deleted=0
 AND (:invite_id=0 OR v.invite_id=:invite_id)
 AND (v.max_uses IS NULL OR NVL(v.used_count,0)<v.max_uses)
 AND (v.expires_at IS NULL OR v.expires_at>=SYSTIMESTAMP)
)
SELECT 1 AS allowed,t.total,e.invite_id,e.invite_code,e.status,e.message,e.max_uses,e.used_count,
 e.expires_at,e.created_at,e.group_id,e.group_name,e.group_slug,e.group_description,e.group_avatar_url,
 e.group_privacy,e.group_member_count,e.inviter_id,e.invitee_id,e.is_valid
FROM (SELECT COUNT(*) AS total FROM eligible) t
LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row
ORDER BY e.rn`;

export async function v2MyGroupInvites(event: H3Event, connection: oracledb.Connection): Promise<V2Response<V2GroupInvite[]>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const page = v2Page(event);
  const raw = getQuery(event).invite_id;
  const inviteId = raw === undefined ? 0 : typeof raw === 'string' &&
    /^[1-9][0-9]*$/.test(raw) && raw.trim() === raw ? Number(raw) : NaN;
  if (!Number.isSafeInteger(inviteId)) v2BadRequest('invite_id 参数错误');
  await v2EnsureGroupFeatureSchema(connection);
  const rows = await v2Rows(connection, groupInviteInboxSql, {
    viewer_id: userId, invite_id: inviteId, start_row: page.start, end_row: page.end
  });
  const invites: V2GroupInvite[] = [];
  for (const row of rows) {
    if (row.INVITE_ID != null) invites.push(await v2MapInvite(connection, userId, row));
  }
  return v2Ok(invites, 'success', v2PageMeta(page.page, page.page_size, v2Number(rows[0]?.TOTAL)));
}

const groupInvitePreviewSql = `SELECT v.group_id,v.inviter_id,v.message,
 CASE WHEN g.is_active=1 AND g.is_deleted=0 THEN v.is_valid ELSE 0 END AS is_valid
FROM v_group_invite_details v JOIN n_groups g ON g.group_id=v.group_id
WHERE v.invite_code=:invite_code AND (v.invitee_id IS NULL OR v.invitee_id=:viewer_id)
ORDER BY v.invite_id ASC FETCH FIRST 2 ROWS ONLY`;

export async function v2InviteCodeInfo(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2InviteCodeData>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  let code: string;
  try { code = decodeURIComponent(v2RouterParam(event, 'code')).trim(); }
  catch { v2BadRequest('code 参数错误'); }
  if (!/^[a-zA-Z0-9]{1,32}$/.test(code)) v2BadRequest('code 参数错误');
  await v2EnsureGroupFeatureSchema(connection);
  const rows = await v2Rows(connection, groupInvitePreviewSql, {
    invite_code: code.toUpperCase(), viewer_id: userId
  });
  const row = rows[0];
  if (!row) v2NotFound('邀请码不存在');
  if (rows.length !== 1 || !v2Boolean(row.IS_VALID)) v2Unprocessable('邀请码无效或已过期');
  const group = await v2RequireGroup(connection, userId, v2Number(row.GROUP_ID));
  if (!group.is_active) v2Unprocessable('邀请码无效或已过期');
  return v2Ok({
    is_valid: true,
    group,
    inviter: await v2RequirePublicUser(connection, userId, v2Number(row.INVITER_ID)),
    message: v2StringOrNull(row.MESSAGE)
  });
}

const directedInviteLookupSql = `SELECT group_id FROM n_group_invites WHERE invite_id=:invite_id AND invitee_id=:viewer_id`;
const directedInviteLockSql = `SELECT inviter_id FROM n_group_invites WHERE invite_id=:invite_id AND group_id=:group_id AND invitee_id=:viewer_id
 AND status='pending' AND (max_uses IS NULL OR NVL(used_count,0)<max_uses)
 AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP) FOR UPDATE`;
const directedInviteWriteSql = `UPDATE n_group_invites SET status=:status, responded_at=SYSTIMESTAMP,
 used_count=CASE WHEN :status='accepted' THEN NVL(used_count,0)+1 ELSE used_count END
 WHERE invite_id=:invite_id AND group_id=:group_id AND invitee_id=:viewer_id
 AND status='pending' AND (max_uses IS NULL OR NVL(used_count,0)<max_uses)
 AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)`;

function directedInviteDecision(body: Record<string, unknown>): boolean {
  const accept = Object.hasOwn(body, 'accept');
  const legacy = Object.hasOwn(body, 'action');
  if (accept !== legacy) {
    if (accept && typeof body.accept === 'boolean') return body.accept;
    if (legacy && body.action === 'accept') return true;
    if (legacy && (body.action === 'decline' || body.action === 'reject')) return false;
  }
  v2BadRequest('accept 参数错误');
}

export async function v2RespondInvite(event: H3Event, connection: oracledb.Connection): Promise<V2Response<V2InviteResponseData>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const inviteId = groupAdmissionId(event, 'invite_id', 'id 参数错误');
  const accept = directedInviteDecision(await groupModerationBody(event, 'accept 参数错误'));
  const status = accept ? 'accepted' : 'rejected';
  try {
    const invite = await v2One(connection, directedInviteLookupSql, { invite_id: inviteId, viewer_id: userId });
    if (!invite) v2NotFound('邀请不存在');
    const groupId = v2Number(invite.GROUP_ID);
    const group = await v2One(connection, groupMembershipLockSql, { group_id: groupId });
    if (!group || v2Number(group.IS_ACTIVE) !== 1 || v2Number(group.IS_DELETED) !== 0) {
      v2Unprocessable('邀请无效或已过期');
    }
    const binds = { invite_id: inviteId, group_id: groupId, viewer_id: userId };
    const locked = await v2One(connection, directedInviteLockSql, binds);
    if (!locked) v2Unprocessable('邀请无效或已过期');

    if (accept && await v2One(connection, groupMembershipReadSql, { group_id: groupId, user_id: userId })) {
      v2Unprocessable('您已经是群组成员');
    }
    const changed = await v2Execute(connection, directedInviteWriteSql, { ...binds, status }, false);
    if (changed === 0) v2Unprocessable('邀请无效或已过期');
    if (changed !== 1) v2ServerError();
    if (accept) {
      const memberId = await v2NextId(connection, 'seq_group_member_id');
      if (!Number.isSafeInteger(memberId) || memberId < 1) v2ServerError();
      if (await v2Execute(connection, `INSERT INTO n_group_members (member_id,group_id,user_id,role,status,invited_by)
VALUES (:member_id,:group_id,:user_id,'member','active',:invited_by)`, {
        member_id: memberId, group_id: groupId, user_id: userId, invited_by: v2Number(locked.INVITER_ID)
      }, false) !== 1) v2ServerError();
    }
    await connection.commit();
    return v2Ok({ invite_id: inviteId, group_id: groupId, status }, `invite ${status}`);
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

const groupAuditLogsSql = `WITH active_group AS (
  SELECT group_id FROM n_groups WHERE group_id=:group_id AND is_active=1 AND is_deleted=0
), allowed_group AS (
  SELECT g.group_id FROM active_group g
  JOIN n_group_members m ON m.group_id=g.group_id AND m.user_id=:user_id
  WHERE m.status='active' AND m.role IN ('owner','admin','moderator')
), ranked AS (
  SELECT l.log_id,l.group_id,l.actor_id,l.target_user_id,l.target_post_id,l.target_comment_id,l.action,l.details,l.ip_address,l.created_at,
    ROW_NUMBER() OVER (ORDER BY l.created_at DESC,l.log_id DESC) AS rn
  FROM allowed_group g JOIN n_group_audit_logs l ON l.group_id=g.group_id
)
SELECT (SELECT COUNT(*) FROM active_group) AS group_exists,
  (SELECT COUNT(*) FROM allowed_group) AS scope_allowed,t.total,
  r.log_id,r.group_id,r.actor_id,r.target_user_id,r.target_post_id,r.target_comment_id,r.action,r.details,r.ip_address,r.created_at
FROM (SELECT COUNT(*) AS total FROM ranked) t
LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
ORDER BY r.rn`;

export async function v2AuditLogs(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2GroupAuditLog[]>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const groupId = groupAdmissionId(event, 'id', 'id 参数错误');
  const page = v2Page(event);
  const rows = await v2Rows(connection, groupAuditLogsSql, {
    user_id: userId, group_id: groupId, start_row: page.start, end_row: page.end
  });
  if (!v2Boolean(rows[0]?.GROUP_EXISTS)) v2NotFound('群组不存在');
  if (!v2Boolean(rows[0]?.SCOPE_ALLOWED)) v2Unprocessable('无权查看审计日志');

  const profiles = new Map<number, Promise<V2PublicUser | null>>();
  const profile = (id: number): Promise<V2PublicUser | null> => {
    if (!id) return Promise.resolve(null);
    const existing = profiles.get(id);
    if (existing) return existing;
    const loaded = v2GetPublicUser(connection, userId, id);
    profiles.set(id, loaded);
    return loaded;
  };
  const logs = await Promise.all(rows.filter(row => row.LOG_ID != null).map(async row => ({
    log_id: v2Number(row.LOG_ID),
    group_id: v2Number(row.GROUP_ID),
    actor_id: v2Number(row.ACTOR_ID),
    actor: await profile(v2Number(row.ACTOR_ID)),
    target_user_id: row.TARGET_USER_ID == null ? null : v2Number(row.TARGET_USER_ID),
    target_user: await profile(v2Number(row.TARGET_USER_ID)),
    target_post_id: row.TARGET_POST_ID == null ? null : v2Number(row.TARGET_POST_ID),
    target_comment_id: row.TARGET_COMMENT_ID == null ? null : v2Number(row.TARGET_COMMENT_ID),
    action: v2String(row.ACTION),
    details: v2JsonValue(row.DETAILS),
    ip_address: v2StringOrNull(row.IP_ADDRESS),
    created_at: v2DateString(row.CREATED_AT) || ''
  })));
  return v2Ok(logs, 'success', v2PageMeta(page.page, page.page_size, v2Number(rows[0]?.TOTAL)));
}
