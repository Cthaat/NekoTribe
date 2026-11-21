import type { Connection } from 'oracledb';
import type { V2ModerationUserItem } from '../../../app/types/v2';
import contract from '../../../specifications/requirements/moderation-user-queue.json';
import { normalizeAvatarPublicUrl } from '~/server/storage';
import { v2Number, v2Rows, v2String, v2StringOrNull } from '~/server/utils/v2';

export async function readModerationUsers(connection: Connection, input: {
  userId?: number;
  status?: string;
  search?: string;
  sort?: string;
  start: number;
  end: number;
}) {
  const { status, search, sort } = input;
  const rows = await v2Rows(connection, contract.sql, {
    user_id: input.userId ?? null,
    status: status === 'all' ? null : status || null,
    q: search?.trim() || null,
    sort: sort && contract.sorts.includes(sort) ? sort : 'newest',
    start_row: input.start,
    end_row: input.end
  });
  const items: V2ModerationUserItem[] = rows.filter(row => v2Number(row.USER_ID) > 0).map(row => ({
    user_id: v2Number(row.USER_ID),
    username: v2String(row.USERNAME),
    display_name: v2String(row.DISPLAY_NAME),
    avatar_url: normalizeAvatarPublicUrl(v2String(row.AVATAR_URL)),
    email: v2String(row.EMAIL),
    status: v2String(row.STATUS),
    is_active: v2Number(row.IS_ACTIVE),
    is_verified: v2Number(row.IS_VERIFIED),
    followers_count: v2Number(row.FOLLOWERS_COUNT),
    posts_count: v2Number(row.POSTS_COUNT),
    likes_count: v2Number(row.LIKES_COUNT),
    report_count: v2Number(row.REPORT_COUNT),
    active_restriction: v2StringOrNull(row.ACTIVE_RESTRICTION),
    restriction_until: v2StringOrNull(row.RESTRICTION_UNTIL),
    created_at: v2String(row.CREATED_AT),
    updated_at: v2String(row.UPDATED_AT)
  }));
  return { items, total: v2Number(rows[0]?.TOTAL) };
}
