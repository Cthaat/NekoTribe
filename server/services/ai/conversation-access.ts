import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { v2Auth, v2BadRequest, v2Forbidden, v2NotFound } from '~/server/utils/v2';
import { v2GroupPermission } from '~/server/services/v2/groups';
import { requireModerationAccess } from '~/server/services/v2/moderation';

export type ConversationPurpose = 'knowledge' | 'writing' | 'group' | 'moderation';
export interface ConversationScope {
  ownerUserId: number;
  purpose: ConversationPurpose;
  groupId: number | null;
}

export async function authorizeConversationScope(
  event: H3Event,
  connection: oracledb.Connection,
  scope: ConversationScope
): Promise<void> {
  const actor = v2Auth(event);
  // Do not reveal whether a different owner's conversation exists.
  if (scope.ownerUserId !== actor.userId) v2NotFound('会话不存在');
  if (scope.purpose === 'group') {
    if (!Number.isSafeInteger(scope.groupId) || (scope.groupId ?? 0) <= 0) v2BadRequest('群组参数错误');
    if (!(await v2GroupPermission(connection, actor.userId, scope.groupId!, 'admin'))) {
      v2Forbidden('需要群管理员权限');
    }
    return;
  }
  if (scope.groupId !== null) v2BadRequest('群组参数错误');
  if (scope.purpose === 'moderation') {
    await requireModerationAccess(event, connection);
    return;
  }
  if (scope.purpose !== 'knowledge' && scope.purpose !== 'writing') v2BadRequest('会话用途错误');
}
