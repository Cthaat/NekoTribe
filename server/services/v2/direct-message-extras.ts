import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/direct-message-extras.json';
import type { V2DirectMessage } from '../../../app/types/v2';
import { v2MapMedia } from '~/server/models/v2';
import { normalizeLocalStorageKey } from '~/server/storage/local-path';
import { v2BadRequest, v2Boolean, v2Execute, v2NotFound, v2Number, v2One, v2RouterParam, v2Rows, v2ServerError, v2String } from '~/server/utils/v2';
import { v2ServiceUnavailable } from '~/server/utils/auth-entry-errors';
import { hasNoDirectExtrasTable, isMissingDirectExtras } from './direct-media-links';

export const directMessageExtras = policy;
const validId = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value > 0;

export function directMessageIds(event: H3Event) {
  function id(name: 'conversation_id' | 'message_id') {
    const raw = v2RouterParam(event,name);
    const numeric = Number(raw);
    if (!/^[1-9][0-9]*$/.test(raw) || !validId(numeric)) v2BadRequest(`${name} 参数错误`);
    return numeric;
  }
  return {conversationId:id('conversation_id'),messageId:id('message_id')};
}

export function directMessageInput(body: Record<string,unknown>) {
  const {content:raw,media_ids:mediaIds = [],reply_to_message_id:replyId = null} = body;
  if (raw !== undefined && typeof raw !== 'string') v2BadRequest('content 参数错误');
  const content = typeof raw === 'string' ? raw.trim() : '';
  if (Buffer.byteLength(content,'utf8') > policy.max_content_bytes) v2BadRequest('content 超过最大长度');
  if (!Array.isArray(mediaIds) || mediaIds.length > policy.max_media || !mediaIds.every(validId) ||
      new Set(mediaIds).size !== mediaIds.length) v2BadRequest('media_ids 参数错误');
  if (replyId !== null && !validId(replyId)) v2BadRequest('reply_to_message_id 参数错误');
  if (!content && !mediaIds.length) v2BadRequest('消息内容或附件不能为空');
  return {content,mediaIds,replyId};
}

export function directMessageEmoji(value: unknown) {
  const emoji = typeof value === 'string' ? value.trim() : '';
  if (!emoji || emoji.length > policy.max_emoji_utf16_units ||
      Buffer.byteLength(emoji,'utf8') > policy.max_emoji_bytes || /[\u0000-\u001f\u007f]/.test(emoji)) {
    v2BadRequest('emoji 参数错误');
  }
  return emoji;
}

export async function lockDirectAttachments(connection: Connection, ownerId: number, mediaIds: number[]) {
  for (const mediaId of [...mediaIds].sort((a,b)=>a-b)) {
    const asset = await v2One(connection,policy.sql.asset_lock,{media_id:mediaId,user_id:ownerId});
    let key: string | null = null;
    if (typeof asset?.STORAGE_KEY === 'string') {
      try { key = normalizeLocalStorageKey(asset.STORAGE_KEY); }
      catch { /* Malformed storage records are inaccessible. */ }
    }
    if (!key?.startsWith('private/chat/') || !await v2One(connection,policy.sql.asset_free,{media_id:mediaId})) {
      v2NotFound('附件不存在或无权使用');
    }
  }
}

export async function attachDirectMessageExtras(connection: Connection, messageId: number, mediaIds: number[], replyId: number | null) {
  if (replyId !== null && await v2Execute(connection,policy.sql.insert_reply,{message_id:messageId,reply_to_message_id:replyId},false) !== 1) {
    v2ServerError();
  }
  for (const [index,mediaId] of mediaIds.entries()) {
    if (await v2Execute(connection,policy.sql.insert_media,{message_id:messageId,media_id:mediaId,position:index+1},false) !== 1) v2ServerError();
  }
}

export async function hydrateDirectMessageExtras(
  connection: Connection,
  viewerId: number,
  messages: V2DirectMessage[],
  allowLegacy = false,
) {
  if (!messages.length) return;
  const byId = new Map(messages.map(message=>[message.message_id,message]));
  const binds = {message_ids:JSON.stringify([...byId.keys()])};
  try {
    const media = await v2Rows(connection,policy.sql.list_media,binds);
    const replies = await v2Rows(connection,policy.sql.list_replies,binds);
    const reactions = await v2Rows(connection,policy.sql.list_reactions,{...binds,viewer_id:viewerId});
    for (const row of media) {
      const message = byId.get(v2Number(row.MESSAGE_ID));
      const assetId = v2Number(row.MEDIA_ID);
      if (!message || !validId(assetId)) v2ServerError();
      (message.media ??= []).push(v2MapMedia({...row,PUBLIC_URL:`/api/v2/media/${assetId}/content`,THUMBNAIL_URL:null}));
    }
    for (const row of replies) {
      const message = byId.get(v2Number(row.MESSAGE_ID));
      const replyId = v2Number(row.REPLY_ID);
      if (!message || !validId(replyId)) v2ServerError();
      message.reply_to = {message_id:replyId,content:v2String(row.REPLY_CONTENT).trim(),author_name:v2String(row.REPLY_AUTHOR_NAME)};
    }
    for (const row of reactions) {
      const message = byId.get(v2Number(row.MESSAGE_ID));
      const count = v2Number(row.REACTION_COUNT);
      const emoji = v2String(row.EMOJI);
      if (!message || !Number.isSafeInteger(count) || count < 1 || !emoji) v2ServerError();
      (message.reactions ??= []).push({emoji,count,reacted_by_me:v2Boolean(row.REACTED_BY_ME)});
    }
  } catch (error) {
    if (!isMissingDirectExtras(error)) throw error;
    if (!allowLegacy || !await hasNoDirectExtrasTable(connection, policy.sql.any_extras_table_present)) {
      v2ServiceUnavailable();
    }
  }
}
