import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/post-polls.json';
import type { V2CreatePostPoll, V2PostPoll } from '../../../app/types/v2';
import { v2BadRequest, v2Boolean, v2Execute, v2NextId, v2Number, v2Rows, v2ServerError, v2String } from '~/server/utils/v2';
import { v2ServiceUnavailable } from '~/server/utils/auth-entry-errors';
import { hasNoDirectExtrasTable as hasNoSchemaTables, isMissingDirectExtras as isMissingTable } from './direct-media-links';

export const postPollSql = policy.sql;
export type PostPollKind = 'post' | 'group';
const rfc3339 = /^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/;

export function readPollCreation(value: unknown): V2CreatePostPoll | undefined {
  if (value === undefined) return;
  if (!value || typeof value !== 'object' || Array.isArray(value)) v2BadRequest('poll 参数错误');
  const {options, multiple, closes_at} = value as Record<string, unknown>;
  if (Object.keys(value).length !== 3 || !Array.isArray(options) || options.length < policy.min_options ||
      options.length > policy.max_options || typeof multiple !== 'boolean' ||
      typeof closes_at !== 'string' || !rfc3339.test(closes_at)) v2BadRequest('poll 参数错误');
  const normalizedOptions = options.map(option => {
    if (typeof option !== 'string') v2BadRequest('投票选项参数错误');
    const text = option.trim();
    if (!text || Buffer.byteLength(text,'utf8') > policy.max_option_bytes) v2BadRequest('投票选项参数错误');
    return text;
  });
  if (new Set(normalizedOptions).size !== normalizedOptions.length) v2BadRequest('投票选项不能重复');
  const date = closes_at.slice(0,10);
  const calendar = new Date(`${date}T00:00:00Z`);
  const cutoff = new Date(closes_at);
  if (!Number.isFinite(calendar.getTime()) || calendar.toISOString().slice(0,10) !== date ||
      !Number.isFinite(cutoff.getTime()) || cutoff.getUTCFullYear() < 1 || cutoff.getUTCFullYear() > 9999) {
    v2BadRequest('投票截止时间参数错误');
  }
  return {options:normalizedOptions,multiple,closes_at:cutoff.toISOString()};
}

export async function attachPostPoll(connection: Connection, kind: PostPollKind, postId: number, poll: V2CreatePostPoll) {
  const poll_id = await v2NextId(connection,'seq_post_poll_id');
  const inserted = await v2Execute(connection,postPollSql.insert_poll,{
    poll_id,post_id:kind === 'post' ? postId : null,group_post_id:kind === 'group' ? postId : null,
    allow_multiple:poll.multiple ? 1 : 0,closes_at:poll.closes_at,
  },false);
  if (inserted === 0) v2BadRequest('投票截止时间必须晚于当前时间');
  if (inserted !== 1) v2ServerError();
  for (const [index,option_text] of poll.options.entries()) {
    if (await v2Execute(connection,postPollSql.insert_option,{poll_id,option_id:index+1,option_text},false) !== 1) v2ServerError();
  }
}

export async function readPostPoll(connection: Connection, viewerId: number | null, kind: PostPollKind, postId: number,
  allowLegacy = false): Promise<V2PostPoll | undefined> {
  let rows;
  try {
    rows = await v2Rows(connection,postPollSql.read,{viewer_id:viewerId,is_group:kind === 'group' ? 1 : 0,post_id:postId});
  } catch (error) {
    if (!isMissingTable(error)) throw error;
    if (allowLegacy && await hasNoSchemaTables(connection,postPollSql.any_table_present)) return;
    v2ServiceUnavailable();
  }
  const first = rows[0];
  if (!first) return;
  const total = v2Number(first.TOTAL_BALLOTS);
  return {
    poll_id:v2Number(first.POLL_ID),multiple:v2Boolean(first.ALLOW_MULTIPLE),closes_at:v2String(first.CLOSES_AT),
    closed:v2Boolean(first.IS_CLOSED),total_ballots:total,
    my_option_ids:rows.filter(row=>v2Boolean(row.SELECTED)).map(row=>v2Number(row.OPTION_ID)),
    options:rows.map(row=>{
      const votes = v2Number(row.VOTES_COUNT);
      return {option_id:v2Number(row.OPTION_ID),text:v2String(row.OPTION_TEXT),votes_count:votes,
        percent:total ? Math.round(votes * 1000 / total) / 10 : 0};
    }),
  };
}
