import { createHash } from 'node:crypto';
import type { H3Event } from 'h3';
import oracledb from 'oracledb';
import { v2Auth, v2BadRequest, v2ServerError } from '~/server/utils/v2';

type SourceKind = 'post' | 'comment';
export interface IndexedSource { kind: SourceKind; id: number; version: string }
export interface KnowledgeSource extends IndexedSource { post_id: number; content: string }
const MAX_ID = 999_999_999_999_999;
const validId = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value > 0 && value <= MAX_ID;

/** Cross-backend fingerprint. Content is untrusted data, never an instruction. */
export function sourceVersion(kind: SourceKind, id: number, postId: number, content: string): string {
  return createHash('sha256').update(`neko-ai-source-v1\0${kind}\0${id}\0${postId}\0`, 'utf8').update(content, 'utf8').digest('hex');
}

/** Reload index candidates from live business tables; stale or invisible rows are omitted. */
export async function hydrateKnowledgeSources(event: H3Event, connection: oracledb.Connection, input: unknown): Promise<KnowledgeSource[]> {
  const actor = v2Auth(event);
  if (!Array.isArray(input) || input.length > 20) v2BadRequest('知识来源参数错误');
  const candidates: IndexedSource[] = [];
  const seen = new Set<string>();
  for (const value of input) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) v2BadRequest('知识来源参数错误');
    const candidate = value as Record<string, unknown>;
    if (Object.keys(candidate).length !== 3 || (candidate.kind !== 'post' && candidate.kind !== 'comment') || !validId(candidate.id) ||
        typeof candidate.version !== 'string' || !/^[0-9a-f]{64}$/.test(candidate.version)) v2BadRequest('知识来源参数错误');
    const key = `${candidate.kind}:${candidate.id}`;
    if (seen.has(key)) v2BadRequest('知识来源参数错误');
    seen.add(key);
    candidates.push({kind:candidate.kind,id:candidate.id,version:candidate.version});
  }
  const output: KnowledgeSource[] = [];
  for (const candidate of candidates) {
    const sql = candidate.kind === 'post'
      ? `SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p
         WHERE p.post_id=:source_id AND p.visibility='public' AND p.is_deleted=0 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND fn_can_view_post(:viewer_id,p.post_id)=1`
      : `SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id
         WHERE c.comment_id=:source_id AND c.is_deleted=0 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1`;
    const result = await connection.execute<Record<string, unknown>>(sql, {source_id:candidate.id,viewer_id:actor.userId}, {
      outFormat:oracledb.OUT_FORMAT_OBJECT,
      fetchTypeHandler: metadata => metadata.name === 'CONTENT' ? {type:oracledb.STRING} : undefined
    });
    const rows = result.rows ?? [];
    if (rows.length > 1) v2ServerError();
    const row = rows[0];
    if (!row) continue;
    const id = Number(row.SOURCE_ID), postId = Number(row.POST_ID), content = row.CONTENT;
    if (!validId(id) || id !== candidate.id || !validId(postId) || (candidate.kind === 'post' && postId !== id) || typeof content !== 'string' || !content.isWellFormed()) v2ServerError();
    if (!content || Buffer.byteLength(content,'utf8') > 65536) continue;
    const version = sourceVersion(candidate.kind,id,postId,content);
    if (version === candidate.version) output.push({kind:candidate.kind,id,post_id:postId,content,version});
  }
  return output;
}
