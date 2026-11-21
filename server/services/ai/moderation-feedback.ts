import { createError as h3Error } from 'h3';
import type { Connection } from 'oracledb';
import { v2BadRequest, v2One } from '~/server/utils/v2';
import contract from '../../../specifications/requirements/ai-moderation-feedback.json';
import { hasTooManyAiBodyMembers } from './knowledge-search-body';

export type ModerationRating = 'helpful' | 'incorrect' | 'insufficient';
export const feedbackSql = contract.queries;

export function validModerationRating(value: unknown): value is ModerationRating {
  return typeof value === 'string' && contract.ratings.includes(value);
}

export function parseModerationFeedback(bytes: Uint8Array): ModerationRating {
  try {
    const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
    const body: unknown = JSON.parse(text);
    if (body && typeof body === 'object' && Object.keys(body).length === 1 &&
        'rating' in body && validModerationRating(body.rating) && !hasTooManyAiBodyMembers(text, 1)) {
      return body.rating;
    }
  } catch { /* Malformed bodies share the public error below. */ }
  v2BadRequest('审核反馈参数错误');
}

export function feedbackUnavailable(): never {
  throw h3Error({statusCode:503,statusMessage:'Service temporarily unavailable',
    data:{code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null}});
}

export async function feedbackTablePresent(connection: Connection): Promise<boolean> {
  try {
    return Boolean(await v2One(connection, feedbackSql.schema));
  } catch {
    feedbackUnavailable();
  }
}

export async function readModerationRating(connection: Connection, messageId: string) {
  try {
    const row = await v2One(connection, feedbackSql.read, {message_id:messageId});
    if (!row) return undefined;
    if (validModerationRating(row.RATING)) return row.RATING;
  } catch { /* Report a sanitized failure for unavailable or incompatible storage. */ }
  feedbackUnavailable();
}
