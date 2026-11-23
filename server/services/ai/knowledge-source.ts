import { createHash } from 'node:crypto';
import type { H3Event } from 'h3';
import oracledb from 'oracledb';
import { v2Auth, v2BadRequest, v2ServerError } from '~/server/utils/v2';
import termsCatalog from '../../../specifications/requirements/ai-public-terms-catalog.json';
import groupSourceQueries from '../../../specifications/requirements/ai-group-knowledge-source.json';
import {parseTermsCatalog,hydratePublicTerms,discoverPublicTerms} from './public-terms-source';
import {readTermsAuthority} from './public-terms-authority';
import {isGroupKnowledgeKind, isKnowledgeKind} from './knowledge-citations';
import { publicKnowledge, scopedKnowledgeSql, type KnowledgeFilter } from './knowledge-scope';

type SourceKind = 'post' | 'comment' | 'group_post' | 'group_comment';
type KnowledgeKind = SourceKind | 'terms';
export interface IndexedSource { kind: KnowledgeKind; id: number; version: string }
export interface KnowledgeSource extends IndexedSource { post_id?: number; group_id?: number; content: string }
const MAX_ID = 999_999_999_999_999;
const validId = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value > 0 && value <= MAX_ID;
const activePostAuthor = 'JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1';
const activeCommentAuthor = 'JOIN n_users comment_author ON comment_author.user_id=c.user_id AND comment_author.is_active=1';
const visibleCommentAuthor = `AND NOT EXISTS (
  SELECT 1 FROM n_user_blocks b
  WHERE (b.user_id=:viewer_id AND b.target_user_id=c.user_id)
     OR (b.target_user_id=:viewer_id AND b.user_id=c.user_id)
)`;

/** Cross-backend fingerprint. Content is untrusted data, never an instruction. */
export function sourceVersion(kind: SourceKind, id: number, postId: number, content: string): string {
  return createHash('sha256').update(`neko-ai-source-v1\0${kind}\0${id}\0${postId}\0`, 'utf8').update(content, 'utf8').digest('hex');
}

/** Internal exact-text discovery; revalidate results immediately before and after generation. */
export async function discoverKnowledgeSources(event: H3Event, connection: oracledb.Connection, query: unknown, limit: unknown, scope = publicKnowledge): Promise<KnowledgeSource[]> {
  const actor = v2Auth(event);
  if (typeof query !== 'string' || !query.isWellFormed() || typeof limit !== 'number' || !Number.isInteger(limit) || limit < 1 || limit > 20) v2BadRequest('知识检索参数错误');
  const term = query.trim();
  if (!term || /[\u0000-\u001f\u007f]/.test(term) || Buffer.byteLength(term, 'utf8') > 256) v2BadRequest('知识检索参数错误');
  const queries: [SourceKind, string][] = scope.kind === 'personal'
    ? [['post', scopedKnowledgeSql.search_personal_post]]
    : scope.kind === 'group'
    ? [['group_post', scopedKnowledgeSql.search_group_post], ['group_comment', scopedKnowledgeSql.search_group_comment]]
    : [
    ['post', `SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p ${activePostAuthor}
      WHERE p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1
      AND p.post_id BETWEEN 1 AND :max_id
      AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(p.content,:term)>0
      ORDER BY p.post_id DESC FETCH FIRST :row_limit ROWS ONLY`],
    ['comment', `SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id
      ${activePostAuthor} ${activeCommentAuthor}
      WHERE c.is_deleted=0 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1
      AND c.comment_id BETWEEN 1 AND :max_id AND p.post_id BETWEEN 1 AND :max_id
      ${visibleCommentAuthor}
      AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND DBMS_LOB.INSTR(c.content,:term)>0
      ORDER BY c.comment_id DESC FETCH FIRST :row_limit ROWS ONLY`],
    ['group_post', groupSourceQueries.search_group_post],
    ['group_comment', groupSourceQueries.search_group_comment],
  ];
  const lists: KnowledgeSource[][] = [];
  for (const [kind, sql] of queries) {
    const result = await connection.execute<Record<string, unknown>>(sql, {viewer_id:actor.userId,term,row_limit:limit,max_id:MAX_ID,
      ...(scope.kind === 'group' ? {group_id:scope.groupId} : {})}, {
      outFormat:oracledb.OUT_FORMAT_OBJECT,
      fetchTypeHandler: metadata => metadata.name === 'CONTENT' ? {type:oracledb.STRING} : undefined
    });
    const rows = result.rows ?? [];
    if (rows.length > limit) v2ServerError();
    const sources: KnowledgeSource[] = [];
    const seen = new Set<number>();
    for (const row of rows) {
      const id = Number(row.SOURCE_ID), postId = Number(row.POST_ID), content = row.CONTENT;
      const groupId = isGroupKnowledgeKind(kind) ? Number(row.GROUP_ID) : undefined;
      if (!validId(id) || !validId(postId) || ((kind === 'post' || kind === 'group_post') && id !== postId) ||
          (isGroupKnowledgeKind(kind) && (scope.kind === 'group' ? groupId !== scope.groupId : !validId(groupId))) ||
          seen.has(id) || typeof content !== 'string' || !content.isWellFormed()) v2ServerError();
      seen.add(id);
      if (!content || Buffer.byteLength(content, 'utf8') > 65536) continue;
      sources.push({kind,id,post_id:postId,content,version:sourceVersion(kind,id,postId,content),...(groupId === undefined ? {} : {group_id:groupId})});
    }
    lists.push(sources);
  }
  const terms=scope.kind === 'public' ? discoverPublicTerms(parseTermsCatalog(termsCatalog),term,limit) : [];
  if(terms.length) await readTermsAuthority(event,connection,termsCatalog);
  lists.splice(2, 0, terms.map<KnowledgeSource>(row=>({kind:'terms',id:row.id,version:row.version,content:[row.title,...row.blocks].join('\n')})).filter(row=>Buffer.byteLength(row.content,'utf8')<=65536));
  const output: KnowledgeSource[] = [];
  for (let i = 0; output.length < limit && lists.some(list=>i<list.length); i++) {
    for (const list of lists) if (list[i] && output.length < limit) output.push(list[i]!);
  }
  return output;
}

/** Reload index candidates from live business tables; stale or invisible rows are omitted. */
export async function hydrateKnowledgeSources(event: H3Event, connection: oracledb.Connection, input: unknown, options:{lockTerms?:boolean; scope?:KnowledgeFilter}={}): Promise<KnowledgeSource[]> {
  const actor = v2Auth(event);
  const scope = options.scope ?? publicKnowledge;
  if (!Array.isArray(input) || input.length > 20) v2BadRequest('知识来源参数错误');
  const candidates: IndexedSource[] = [];
  const seen = new Set<string>();
  for (const value of input) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) v2BadRequest('知识来源参数错误');
    const candidate = value as Record<string, unknown>;
    if (Object.keys(candidate).length !== 3 ||
        !isKnowledgeKind(candidate.kind) ||
        !validId(candidate.id) || (candidate.kind === 'terms' && candidate.id > 8) ||
        typeof candidate.version !== 'string' || !/^[0-9a-f]{64}$/.test(candidate.version)) v2BadRequest('知识来源参数错误');
    const key = `${candidate.kind}:${candidate.id}`;
    if (seen.has(key)) v2BadRequest('知识来源参数错误');
    seen.add(key);
    if (scope.kind === 'group' && !isGroupKnowledgeKind(candidate.kind)) continue;
    if (scope.kind === 'personal' && candidate.kind !== 'post') continue;
    candidates.push({kind:candidate.kind,id:candidate.id,version:candidate.version});
  }
  const terms=candidates.filter(candidate=>candidate.kind==='terms');
  let hydratedTerms:ReturnType<typeof hydratePublicTerms>=[];
  if(terms.length) {
    await readTermsAuthority(event,connection,termsCatalog,{lock:options.lockTerms===true});
    hydratedTerms=hydratePublicTerms(parseTermsCatalog(termsCatalog),terms.map(ref=>({kind:'terms',id:ref.id,version:ref.version})));
  }
  const output: KnowledgeSource[] = [];
  for (const candidate of candidates) {
    if(candidate.kind==='terms') {
      const term=hydratedTerms.find(row=>row.id===candidate.id && row.version===candidate.version);
      if(term) {
        const content=[term.title,...term.blocks].join('\n');
        if(Buffer.byteLength(content,'utf8')<=65536) output.push({kind:'terms',id:term.id,version:term.version,content});
      }
      continue;
    }
    const sql = scope.kind === 'personal' ? scopedKnowledgeSql.personal_post
      : scope.kind === 'group' && isGroupKnowledgeKind(candidate.kind) ? scopedKnowledgeSql[candidate.kind]
      : isGroupKnowledgeKind(candidate.kind)
      ? groupSourceQueries[candidate.kind]
      : candidate.kind === 'post'
      ? `SELECT p.post_id AS source_id,p.post_id AS post_id,p.content AS content FROM n_posts p ${activePostAuthor}
         WHERE p.post_id=:source_id AND p.post_id BETWEEN 1 AND :max_id AND p.visibility='public' AND p.is_deleted=0 AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536 AND fn_can_view_post(:viewer_id,p.post_id)=1`
      : `SELECT c.comment_id AS source_id,p.post_id AS post_id,c.content AS content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id
         ${activePostAuthor} ${activeCommentAuthor}
         WHERE c.comment_id=:source_id AND c.is_deleted=0 AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536 AND p.visibility='public' AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1
         AND p.post_id BETWEEN 1 AND :max_id
         ${visibleCommentAuthor}`;
    const result = await connection.execute<Record<string, unknown>>(sql, {source_id:candidate.id,viewer_id:actor.userId,max_id:MAX_ID,
      ...(scope.kind === 'group' ? {group_id:scope.groupId} : {})}, {
      outFormat:oracledb.OUT_FORMAT_OBJECT,
      fetchTypeHandler: metadata => metadata.name === 'CONTENT' ? {type:oracledb.STRING} : undefined
    });
    const rows = result.rows ?? [];
    if (rows.length > 1) v2ServerError();
    const row = rows[0];
    if (!row) continue;
    const id = Number(row.SOURCE_ID), postId = Number(row.POST_ID), content = row.CONTENT;
    const groupId = isGroupKnowledgeKind(candidate.kind) ? Number(row.GROUP_ID) : undefined;
    if (!validId(id) || id !== candidate.id || !validId(postId) ||
        ((candidate.kind === 'post' || candidate.kind === 'group_post') && postId !== id) ||
        typeof content !== 'string' || !content.isWellFormed()) v2ServerError();
    if (isGroupKnowledgeKind(candidate.kind) && (scope.kind === 'group' ? groupId !== scope.groupId : !validId(groupId))) v2ServerError();
    if (!content || Buffer.byteLength(content,'utf8') > 65536) continue;
    const version = sourceVersion(candidate.kind,id,postId,content);
    if (version === candidate.version) output.push({kind:candidate.kind,id,post_id:postId,content,version,...(groupId === undefined ? {} : {group_id:groupId})});
  }
  return output;
}
