import { getRouterParam } from 'h3';
import type { H3Event } from 'h3';
import { v2BadRequest } from './v2';

/** Require a canonical positive integer that JavaScript and the other backends represent exactly. */
export function v2SafeRouterId(event: H3Event, key: string): number {
  const raw = getRouterParam(event, key, { decode: true }) ?? '';
  const id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(id)) v2BadRequest(`${key} 参数错误`);
  return id;
}
