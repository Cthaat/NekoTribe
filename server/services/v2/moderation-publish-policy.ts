import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/moderation-publish-policy.json';
import { v2Forbidden, v2Number, v2One } from '~/server/utils/v2';

/** Hold the same account row that moderation updates until the caller commits or rolls back. */
export async function requirePublishAccess(connection: Connection, userId: number) {
  const binds = {user_id:userId};
  if (!await v2One(connection,policy.sql.lock,binds)) v2Forbidden(policy.message);
  const row = await v2One(connection,policy.sql.allowed,binds);
  if (v2Number(row?.ALLOWED) !== 1) v2Forbidden(policy.message);
}
