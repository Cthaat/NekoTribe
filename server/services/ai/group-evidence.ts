import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/ai-group-evidence.json';
import { v2Auth, v2BadRequest, v2Forbidden, v2Rows, v2ServerError } from '~/server/utils/v2';

interface EvidenceOptions {
  lookbackDays: 7 | 30;
  searchTerm?: string;
  matchExcerpt?: boolean;
  windowEnd?: string;
}

export interface GroupEvidence {
  window_start: string;
  window_end: string;
  posts_count: number;
  comments_count: number;
  examples: Array<{ kind: 'post' | 'comment'; source_id: number; post_id: number; excerpt: string }>;
}

const timestamp = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$/;
const validTimestamp = (value: unknown): value is string => typeof value === 'string' && value.length === 26 && timestamp.test(value);
const safeNumber = (value: unknown, min: number): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= min;

/** groupId is taken from the authenticated conversation, not from the model or request body. */
export async function readGroupEvidence(
  event: H3Event,
  connection: Connection,
  groupId: number,
  { lookbackDays, searchTerm, matchExcerpt = false, windowEnd }: EvidenceOptions
): Promise<GroupEvidence> {
  const actorId = v2Auth(event).userId;
  if (!safeNumber(groupId, 1) || (lookbackDays !== 7 && lookbackDays !== 30) ||
      (searchTerm !== undefined && (!searchTerm || !searchTerm.isWellFormed() ||
        Buffer.byteLength(searchTerm, 'utf8') > 256 || /[\u0000-\u001f\u007f]/.test(searchTerm))) ||
      (windowEnd !== undefined && !validTimestamp(windowEnd))) {
    v2BadRequest('群运营资料参数错误');
  }

  const rows = await v2Rows(connection, contract.query, {
    actor_id: actorId, group_id: groupId, lookback_days: lookbackDays,
    search_term: searchTerm ?? null, match_excerpt: matchExcerpt ? 1 : 0, window_end: windowEnd ?? null,
  });
  const first = rows[0];
  if (!first) v2Forbidden('需要公开群的管理员权限');
  const { WINDOW_START, WINDOW_END, POSTS_COUNT, COMMENTS_COUNT } = first;
  if (rows.length > 8 || !validTimestamp(WINDOW_START) || !validTimestamp(WINDOW_END) ||
      WINDOW_START >= WINDOW_END || (windowEnd !== undefined && WINDOW_END !== windowEnd) ||
      !safeNumber(POSTS_COUNT, 0) || !safeNumber(COMMENTS_COUNT, 0)) {
    v2ServerError();
  }
  const evidence: GroupEvidence = {
    window_start: WINDOW_START, window_end: WINDOW_END,
    posts_count: POSTS_COUNT, comments_count: COMMENTS_COUNT, examples: [],
  };
  for (const row of rows) {
    if (row.WINDOW_START !== WINDOW_START || row.WINDOW_END !== WINDOW_END ||
        row.POSTS_COUNT !== POSTS_COUNT || row.COMMENTS_COUNT !== COMMENTS_COUNT) v2ServerError();
    const { KIND, SOURCE_ID, POST_ID, EXCERPT } = row;
    if (KIND === null && rows.length === 1 && SOURCE_ID === null && POST_ID === null && EXCERPT === null) break;
    if ((KIND !== 'post' && KIND !== 'comment') || !safeNumber(SOURCE_ID, 1) || !safeNumber(POST_ID, 1) ||
        (KIND === 'post' && SOURCE_ID !== POST_ID) || typeof EXCERPT !== 'string' ||
        !EXCERPT || !EXCERPT.isWellFormed() || [...EXCERPT].length > 400) v2ServerError();
    evidence.examples.push({ kind: KIND, source_id: SOURCE_ID, post_id: POST_ID, excerpt: EXCERPT });
  }
  return evidence;
}
