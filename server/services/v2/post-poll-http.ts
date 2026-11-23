import { setResponseHeader, type H3Event } from 'h3';
import type { Connection } from 'oracledb';
import { requireFeatureSchema } from '~/server/database/readiness';
import { v2Auth, v2BadRequest, v2Body, v2Boolean, v2Conflict, v2Execute, v2Forbidden, v2NotFound, v2Ok,
  v2One, v2OptionalAuth, v2RouterParam, v2ServerError } from '~/server/utils/v2';
import { v2RequireGroupPostRow, withGroupContentWrite } from './groups';
import { postPollSql, readPostPoll, type PostPollKind } from './post-polls';

type Target = { kind:'post'; postId:number } | { kind:'group'; postId:number; groupId:number };

function pollTarget(event: H3Event, kind: PostPollKind): Target {
  function id(name: 'id' | 'post_id') {
    const raw = v2RouterParam(event, name);
    const value = Number(raw);
    if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(value)) v2BadRequest(`${name} 参数错误`);
    return value;
  }
  return kind === 'group' ? {kind,groupId:id('id'),postId:id('post_id')} : {kind,postId:id('id')};
}

async function requireVisiblePost(connection: Connection, viewerId: number | null, target: Target, lock = false) {
  if (target.kind === 'group') {
    if (viewerId === null) v2Forbidden('无权访问群组');
    await v2RequireGroupPostRow(connection, viewerId, target.groupId, target.postId);
    if (lock) {
      const access = await v2One(connection, 'SELECT fn_can_post_in_group(:user_id,:group_id) AS allowed FROM dual', {
        user_id: viewerId, group_id: target.groupId,
      });
      if (!v2Boolean(access?.ALLOWED)) v2Forbidden('无权参与群组投票');
    }
    return;
  }
  const row = await v2One(connection, `SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0
    AND EXISTS (SELECT 1 FROM v_post_feed_item v WHERE v.post_id=p.post_id)
    AND fn_can_view_post(:viewer_id,p.post_id)=1${lock ? ' FOR UPDATE OF p.post_id' : ''}`,
  {post_id:target.postId,viewer_id:viewerId});
  if (!row) v2NotFound('帖子不存在');
}

export async function v2ReadPostPoll(event: H3Event, connection: Connection, kind: PostPollKind) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const viewer = kind === 'group' ? v2Auth(event).userId : v2OptionalAuth(event)?.userId ?? null;
  const target = pollTarget(event, kind);
  await requireFeatureSchema(connection, 'post-polls');
  await requireVisiblePost(connection, viewer, target);
  const poll = await readPostPoll(connection, viewer, kind, target.postId);
  if (!poll) v2NotFound('投票不存在');
  return v2Ok(poll);
}

function isDuplicateBallot(error: unknown): boolean {
  return typeof error === 'object' && error !== null &&
    (('errorNum' in error && error.errorNum === 1) || ('code' in error && error.code === 'ORA-00001'));
}

export async function v2VotePostPoll(event: H3Event, connection: Connection, kind: PostPollKind) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const {userId} = v2Auth(event);
  const target = pollTarget(event, kind);
  const body = await v2Body(event);
  const choices = body.option_ids;
  if (Object.keys(body).length !== 1 || !Array.isArray(choices) || choices.length < 1 || choices.length > 6 ||
      choices.some(id => typeof id !== 'number' || !Number.isInteger(id) || id < 1 || id > 6) ||
      new Set(choices).size !== choices.length) v2BadRequest('option_ids 参数错误');
  await requireFeatureSchema(connection, 'post-polls');

  const vote = async () => {
    await requireVisiblePost(connection, userId, target, true);
    const poll = await readPostPoll(connection, userId, kind, target.postId);
    if (!poll) v2NotFound('投票不存在');
    if (poll.closed) v2Conflict('投票已截止');
    if (poll.my_option_ids.length) v2Conflict('已提交选票');
    if (!poll.multiple && choices.length !== 1 || choices.some(id => !poll.options.some(option => option.option_id === id))) {
      v2BadRequest('投票选项与原帖不匹配');
    }
    const binds = {poll_id:poll.poll_id,user_id:userId};
    let affected: number;
    try { affected = await v2Execute(connection,postPollSql.insert_ballot,binds,false); }
    catch (error) { if (isDuplicateBallot(error)) v2Conflict('已提交选票'); throw error; }
    if (affected === 0) v2Conflict('投票已截止');
    if (affected !== 1) v2ServerError();
    for (const option_id of choices) {
      if (await v2Execute(connection,postPollSql.insert_vote,{...binds,option_id},false) !== 1) v2ServerError();
    }
    const result = await readPostPoll(connection,userId,kind,target.postId);
    if (!result) v2ServerError();
    return v2Ok(result,'vote recorded');
  };

  if (target.kind === 'group') return withGroupContentWrite(connection, userId, target.groupId, vote);
  try {
    const result = await vote();
    await connection.commit();
    return result;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}
