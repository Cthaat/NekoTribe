import oracledb, { type Connection } from 'oracledb';
import policy from '../../../specifications/requirements/post-markdown.json';
import { v2BadRequest, v2Execute, v2ServerError } from '~/server/utils/v2';
import { v2ServiceUnavailable } from '~/server/utils/auth-entry-errors';
import { hasNoDirectExtrasTable, isMissingDirectExtras } from './direct-media-links';

type MarkdownScope = 'post' | 'group';
const { sql } = policy;

export function readPostMarkdownInput(value: unknown): string | undefined {
  if (value === undefined) return;
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > policy.max_markdown_bytes) {
    v2BadRequest('markdown 必须为非空正文且不超过 16 KiB');
  }
  return value;
}

export async function attachPostMarkdown(connection: Connection, scope: MarkdownScope, id: number, markdown: string) {
  const binds = { post_id: scope === 'post' ? id : null, group_post_id: scope === 'group' ? id : null, markdown_body: markdown };
  if (await v2Execute(connection, sql.insert, binds, false) !== 1) v2ServerError();
}

export async function updatePostMarkdown(connection: Connection, postId: number, markdown: string | null) {
  const key = { post_id: postId };
  if (markdown === null) {
    await v2Execute(connection, sql.remove, key, false);
    return;
  }
  const updated = await v2Execute(connection, sql.update, { ...key, markdown_body: markdown }, false);
  if (!updated) await attachPostMarkdown(connection, 'post', postId, markdown);
}

export async function readPostMarkdown(connection: Connection, scope: MarkdownScope, id: number): Promise<string | undefined> {
  try {
    const result = await connection.execute<{ MARKDOWN_BODY: string }>(sql.read, {
      post_id: id, is_group: scope === 'group' ? 1 : 0,
    }, {
      outFormat: oracledb.OUT_FORMAT_OBJECT,
      fetchTypeHandler: metadata => metadata.name === 'MARKDOWN_BODY' ? { type: oracledb.STRING } : undefined,
    });
    return result.rows?.[0]?.MARKDOWN_BODY;
  } catch (error) {
    if (!isMissingDirectExtras(error)) throw error;
    if (await hasNoDirectExtrasTable(connection, sql.present)) return;
    v2ServiceUnavailable();
  }
}
