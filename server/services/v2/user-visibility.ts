import { getRouterParam, readBody, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import sql from '../../../specifications/requirements/user-visibility-sql.json';
import { v2MapPublicUser } from '~/server/models/v2';
import {
  v2Auth, v2BadRequest, v2Execute, v2Forbidden, v2NotFound, v2Number, v2Ok, v2One, v2Page, v2PageMeta,
  v2Record, v2Rows, v2ServerError, v2String, v2Unprocessable
} from '~/server/utils/v2';
import { v2CreateNotification } from './notifications';

const zonedExpiry = /^(?!0000)[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$/;

export function muteExpiry(value: unknown): string | null {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || !zonedExpiry.test(value)) v2BadRequest('expires_at 参数错误');
  const calendar = new Date(value.slice(0, 10) + 'T00:00:00Z');
  const expiry = new Date(value);
  if (!Number.isFinite(calendar.getTime()) || !Number.isFinite(expiry.getTime()) ||
      calendar.toISOString().slice(0, 10) !== value.slice(0, 10) ||
      expiry.getUTCFullYear() < 1 || expiry.getUTCFullYear() > 9999) v2BadRequest('expires_at 参数错误');
  return expiry.toISOString();
}

type Kind = 'blocks' | 'mutes';
type FollowList = 'followers' | 'following' | 'mutual-following';

function relationshipTarget(event: H3Event, param: 'id' | 'target_id'): number {
  const raw = getRouterParam(event, param, { decode: true }) ?? '';
  const id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(id)) v2BadRequest(`${param} 参数错误`);
  return id;
}

async function lockUserPair(connection: Connection, actor: number, target: number): Promise<boolean> {
  for (const id of new Set([Math.min(actor, target), Math.max(actor, target)])) {
    if (!await v2One(connection, sql.lockUser, { user_id: id })) return false;
  }
  return true;
}

export async function v2VisibilityList(event: H3Event, connection: Connection, kind: Kind | FollowList) {
  const { userId } = v2Auth(event);
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const page = v2Page(event);
  const target = kind === 'blocks' || kind === 'mutes' ? {} : { target_id: relationshipTarget(event, 'id') };
  const rows = await v2Rows(connection, sql[kind], {
    viewer_id: userId, start_row: page.start, end_row: page.end, ...target
  });
  const data = rows.filter(row => Number(row.USER_ID) > 0).map(row => ({
    ...v2MapPublicUser(row),
    ...(kind === 'mutes' ? { expires_at: row.EXPIRES_AT ?? null } : {})
  }));
  return v2Ok(data, 'success', v2PageMeta(page.page, page.page_size, Number(rows[0]?.TOTAL ?? 0)));
}

export async function v2VisibilityWrite(
  event: H3Event, connection: Connection, kind: Kind, remove: boolean
) {
  const { userId } = v2Auth(event);
  const targetId = relationshipTarget(event, 'target_id');
  const binds = { actor_id: userId, target_id: targetId };
  if (remove) {
    await v2Execute(connection, kind === 'blocks' ? sql.unblock : sql.unmute, binds);
    return v2Ok({ target_user_id: targetId, relationship: 'none' });
  }
  if (userId === targetId) v2Unprocessable(kind === 'blocks' ? '不能屏蔽自己' : '不能静音自己');
  let expiresAt: string | null = null;
  if (kind === 'mutes') {
    const rawBody = await readBody(event);
    expiresAt = muteExpiry(rawBody === undefined ? undefined : v2Record(rawBody).expires_at);
  }
  try {
    if (!await lockUserPair(connection, userId, targetId)) v2NotFound('用户不存在');
    if (!await v2One(connection, sql.activeTarget, { target_id: targetId })) v2NotFound('用户不存在');
    if (kind === 'blocks') {
      await v2Execute(connection, sql.block, binds, false);
      await v2Execute(connection, sql.cancelFollows, binds, false);
    } else {
      await v2Execute(connection, sql.mute, {
        ...binds, expires_at: expiresAt?.replace('Z', '+00:00') ?? null
      }, false);
    }
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  return kind === 'blocks'
    ? v2Ok({ target_user_id: targetId, relationship: 'blocking' })
    : v2Ok({ target_user_id: targetId, relationship: 'muted', expires_at: expiresAt });
}

export async function v2WriteFollow(event: H3Event, connection: Connection, remove: boolean) {
  const actor = v2Auth(event).userId;
  const target = relationshipTarget(event, 'id');
  if (!remove && actor === target) v2Unprocessable('不能关注自己');
  const binds = { actor_id: actor, target_id: target };
  let changed = 0;
  let count = 0;
  try {
    const locked = await lockUserPair(connection, actor, target);
    if (!remove) {
      if (!locked || !await v2One(connection, sql.activeTarget, { target_id: target })) v2NotFound('用户不存在');
      if (v2Number((await v2One(connection, sql.blocked, binds))?.TOTAL) > 0) v2Forbidden('无法关注该用户');
    }
    if (locked) {
      changed = await v2Execute(connection, remove ? sql.unfollow : sql.follow, binds, false);
      if (changed > 1) v2ServerError();
      count = v2Number((await v2One(connection, sql.followCount, { target_id: target }))?.FOLLOWERS_COUNT);
    }
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  if (!remove && changed === 1) {
    try {
      const name = await v2One(connection, sql.followActor, { actor_id: actor });
      await v2CreateNotification(connection, {
        userId: target, actorId: actor, type: 'follow',
        title: `${v2String(name?.NAME, '有人')} 关注了你`, message: '你收到了一个新的关注。',
        resourceType: 'user', resourceId: actor, metadata: { target_user_id: actor, event: 'user_follow' }
      });
    } catch {
      console.warn('follow notification unavailable');
    }
  }
  return v2Ok({ target_user_id: target, relationship: remove ? 'none' : 'following', followers_count: count });
}
