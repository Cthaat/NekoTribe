import policy from '../../../specifications/requirements/chat-message-search.json';
import { v2BadRequest } from '~/server/utils/v2';

const rfc3339 = /^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/;

function timestamp(value: unknown, name: string): string | undefined {
  if (value === undefined) return;
  if (typeof value !== 'string' || !rfc3339.test(value)) v2BadRequest(`${name} 参数错误`);
  const date = value.slice(0, 10);
  const day = new Date(`${date}T00:00:00Z`);
  const instant = new Date(value);
  if (date.startsWith('0000') || !Number.isFinite(instant.getTime()) || !Number.isFinite(day.getTime()) ||
      day.toISOString().slice(0, 10) !== date || instant.getUTCFullYear() < 1 ||
      instant.getUTCFullYear() > 9999) v2BadRequest(`${name} 参数错误`);
  return instant.toISOString().replace(/Z$/, '+00:00');
}

export function chatMessageSearch(query: Record<string, unknown>, kind: 'channel' | 'direct') {
  const alias = kind === 'channel' ? 'm' : 'dm';
  const filters: string[] = [];
  const binds: Record<string, string | number> = {};
  const add = (predicate: string, name: string, value: string | number) => {
    filters.push(predicate.replaceAll('{message}', alias));
    binds[name] = value;
  };
  if (query.q !== undefined && typeof query.q !== 'string') v2BadRequest('q 参数错误');
  const keyword = query.q?.trim();
  if (keyword) {
    if (Buffer.byteLength(keyword, 'utf8') > policy.max_keyword_bytes) v2BadRequest('q 超过最大长度');
    add(policy.sql.keyword, 'search_keyword', keyword);
  }
  const rawSender = query.sender_id;
  if (rawSender !== undefined) {
    const sender = Number(rawSender);
    if (typeof rawSender !== 'string' || !/^[1-9][0-9]*$/.test(rawSender) || !Number.isSafeInteger(sender)) {
      v2BadRequest('sender_id 参数错误');
    }
    add(kind === 'channel' ? policy.sql.channel_sender : policy.sql.direct_sender, 'search_sender', sender);
  }
  const start = timestamp(query.start_at, 'start_at');
  const end = timestamp(query.end_at, 'end_at');
  if (start && end && start >= end) v2BadRequest('开始时间须早于结束时间');
  if (start) add(policy.sql.start, 'search_start', start);
  if (end) add(policy.sql.end, 'search_end', end);
  return { active: filters.length > 0, where: filters.join('\n'), binds };
}
