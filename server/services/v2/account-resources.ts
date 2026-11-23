import { getQuery, setResponseHeader, type H3Event } from 'h3';
import oracledb from 'oracledb';
import contract from '../../../specifications/requirements/account-resources.json';
import { safeV2Action } from '~/server/utils/auth-entry-errors';
import { readAiAccountQuota } from '~/server/utils/ai-model-quota';
import { v2Auth, v2BadRequest, v2Ok, v2One, v2Rows, v2WithConnection } from '~/server/utils/v2';

export async function getAccountUsage(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const user_id = v2Auth(event).userId;
  const ai_quota = await readAiAccountQuota(event.context.aiQuotaRedis, user_id);
  return safeV2Action(() => v2WithConnection(event, async connection => {
    const row = await v2One(connection, contract.sql.usage, { user_id });
    return v2Ok({
      ai_quota,
      media: { bytes: Number(row?.BYTES ?? 0), files: Number(row?.FILES ?? 0) },
      ai_history: { conversations: Number(row?.CONVERSATIONS ?? 0) }
    });
  }));
}

interface Bookmark {
  post_id: number;
  created_at: string;
}

interface ExportPost extends Bookmark {
  content: string | null;
}

function markdown(posts: ExportPost[], bookmarks: Bookmark[]) {
  const lines = ['# NekoTribe account export', '', '## Posts', ''];
  for (const post of posts) {
    lines.push(`### Post ${post.post_id}`, '', post.created_at, '');
    if (post.content) {
      for (const line of post.content.replace(/\r\n?/g, '\n').split('\n')) lines.push(`    ${line}`);
      lines.push('');
    }
  }
  lines.push('## Bookmarks', '');
  for (const bookmark of bookmarks) lines.push(`- Post ${bookmark.post_id} · ${bookmark.created_at}`);
  return lines.join('\n') + '\n';
}

export async function exportAccountData(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const user_id = v2Auth(event).userId;
  const format = getQuery(event).format ?? 'json';
  if (format !== 'json' && format !== 'markdown') v2BadRequest('format 参数错误');
  const { data } = await safeV2Action(() => v2WithConnection(event, async connection => {
    const { rows } = await connection.execute<{ POST_ID: number; CONTENT: string | null; CREATED_AT: string }>(
      contract.sql.posts, { user_id }, {
        outFormat: oracledb.OUT_FORMAT_OBJECT,
        fetchTypeHandler: metadata => metadata.dbType === oracledb.DB_TYPE_CLOB ? { type: oracledb.STRING } : undefined
      }
    );
    const posts = (rows ?? []).map(row => ({
      post_id: row.POST_ID, content: row.CONTENT, created_at: row.CREATED_AT
    }));
    const bookmarkRows = await v2Rows(connection, contract.sql.bookmarks, { user_id });
    const bookmarks = bookmarkRows.map(row => ({
      post_id: Number(row.POST_ID), created_at: String(row.CREATED_AT)
    }));
    return v2Ok({ posts, bookmarks });
  }));
  const extension = format === 'json' ? 'json' : 'md';
  setResponseHeader(event, 'Content-Disposition', `attachment; filename="nekotribe-account.${extension}"`);
  setResponseHeader(event, 'Content-Type', format === 'json' ? 'application/json; charset=utf-8' : 'text/markdown; charset=utf-8');
  return format === 'json' ? data : markdown(data.posts, data.bookmarks);
}
