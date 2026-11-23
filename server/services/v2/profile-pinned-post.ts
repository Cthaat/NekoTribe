import { setResponseHeader, type H3Event } from 'h3';
import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/profile-pinned-post.json';
import { requireFeatureSchema } from '~/server/database/readiness';
import { v2GetPostById } from '~/server/models/v2';
import { v2SafeRouterId } from '~/server/utils/router-id';
import { v2Auth, v2BadRequest, v2Body, v2Execute, v2NotFound, v2Number, v2Ok, v2One, v2ServerError } from '~/server/utils/v2';

type PinAction = 'read' | 'set' | 'clear';
type PinResponse = { post: V2Post | null } | { post_id: number } | null;
const { sql } = policy;

async function writePin(connection: Connection, userId: number, postId: number | null) {
  const owner = { user_id: userId };
  try {
    if (!await v2One(connection, sql.owner, owner)) v2NotFound('账号不存在');
    if (postId === null) {
      await v2Execute(connection, sql.remove, owner, false);
    } else {
      const target = {...owner,post_id:postId};
      if (!await v2One(connection, sql.eligible, target)) v2NotFound('帖子不存在');
      if (await v2Execute(connection, sql.write, target, false) !== 1) v2ServerError();
    }
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2ProfilePin(event: H3Event, connection: Connection, action: PinAction): Promise<V2Response<PinResponse>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  if (action === 'read') {
    const profileId = v2SafeRouterId(event, 'id');
    await requireFeatureSchema(connection, 'profile-pinned-post');
    const row = await v2One(connection, sql.read, {profile_id:profileId,viewer_id:userId});
    return v2Ok({post:row ? await v2GetPostById(connection,userId,v2Number(row.POST_ID)) : null});
  }
  if (action === 'clear') {
    await requireFeatureSchema(connection, 'profile-pinned-post');
    await writePin(connection,userId,null);
    return v2Ok(null,'post unpinned');
  }
  const body = await v2Body(event);
  const { post_id } = body;
  if (Object.keys(body).length !== 1 || typeof post_id !== 'number' || !Number.isSafeInteger(post_id) || post_id < 1) {
    v2BadRequest('post_id 参数错误');
  }
  await requireFeatureSchema(connection, 'profile-pinned-post');
  await writePin(connection,userId,post_id);
  return v2Ok({post_id},'post pinned');
}
