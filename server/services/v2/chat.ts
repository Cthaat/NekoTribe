import { requirePublishAccess } from './moderation-publish-policy';
import directRealtimeAccess from '../../../specifications/requirements/direct-realtime-access.json';
import directDelete from '../../../specifications/requirements/direct-message-delete.json';
import type { H3Event } from 'h3';
import { getQuery, readRawBody } from 'h3';
import type oracledb from 'oracledb';
import type {
  V2ApiResponse as V2Response,
  V2ChatChannel,
  V2ChatChannelLastMessage,
  V2ChatChannelMuteData,
  V2ChatChannelType,
  V2ChatGroup,
  V2ChatMember,
  V2ChatMessage,
  V2ChatReactionSummary,
  V2ChatReadStatusData,
  V2CreateChatChannelPayload,
  V2CreateDirectConversationPayload,
  V2CreateDirectMessagePayload,
  V2DirectConversation,
  V2DirectLastMessage,
  V2DirectMessage,
  V2GroupRole,
  V2MediaAsset
} from '../../../app/types/v2';
import { normalizeStoragePublicUrl } from '~/server/storage';
import type { WSMessage } from '~/server/utils/redis';
import {
  REDIS_CHANNELS,
  publishMessage
} from '~/server/utils/redis';
import {
  WS_SERVER_ID,
  sendWsToRoom,
  sendWsToUser
} from '~/server/utils/wsSession';
import type { V2DbRecord } from '~/server/utils/v2';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2BoolNumber,
  v2Boolean,
  v2Count,
  v2Conflict,
  v2DateString,
  v2Execute,
  v2Forbidden,
  v2NextId,
  v2NotFound,
  v2Null,
  v2Number,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryString,
  v2RequiredString,
  v2Rows,
  v2ServerError,
  v2String
} from '~/server/utils/v2';
import { v2MapMedia, v2MapPublicUser } from '~/server/models/v2';
import { v2DeliverStoredNotification, v2StoreNotification } from './notifications';
import { canBindMedia } from './private-media-binding';

interface ChatMembership {
  groupId: number;
  role: V2GroupRole;
  status: string;
  canManage: boolean;
}

interface ChatChannelAccess extends ChatMembership {
  channelId: number;
  channelType: V2ChatChannelType;
  isPrivate: boolean;
}

function v2NormalizeChatChannelType(
  value: string
): V2ChatChannelType {
  if (
    value === 'text' ||
    value === 'announcement' ||
    value === 'voice' ||
    value === 'video'
  ) {
    return value;
  }
  v2BadRequest('type 参数错误');
}

function v2ChatRoomId(channelId: number): string {
  return `chat:channel:${channelId}`;
}

function v2ChatRedisChannel(channelId: number): string {
  return `${REDIS_CHANNELS.CHAT_CHANNEL}${channelId}`;
}

function v2ChatLastMessage(
  row: V2DbRecord
): V2ChatChannelLastMessage | null {
  const messageId = v2Number(row.LAST_MESSAGE_ID);
  if (!messageId) return null;
  return {
    message_id: messageId,
    content: v2String(row.LAST_MESSAGE_CONTENT),
    author_name: v2String(row.LAST_MESSAGE_AUTHOR),
    created_at: v2DateString(row.LAST_MESSAGE_AT) || ''
  };
}

function v2MapChatChannel(
  row: V2DbRecord,
  canManage: boolean
): V2ChatChannel {
  return {
    channel_id: v2Number(row.CHANNEL_ID),
    group_id: v2Number(row.GROUP_ID),
    name: v2String(row.NAME),
    type: v2NormalizeChatChannelType(v2String(row.CHANNEL_TYPE)),
    category: v2String(row.CATEGORY, '文字频道'),
    position: v2Number(row.POSITION),
    is_private: v2Boolean(row.IS_PRIVATE),
    is_muted_by_me: v2Boolean(row.IS_MUTED_BY_ME),
    unread_count: v2Number(row.UNREAD_COUNT),
    last_message: v2ChatLastMessage(row),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || '',
    can_manage: canManage
  };
}

function v2MapChatMember(row: V2DbRecord): V2ChatMember {
  const status = v2String(row.STATUS);
  const onlineStatus = (() => {
    const value = v2String(row.ONLINE_STATUS);
    if (value === 'online' || value === 'hidden') return value;
    return 'offline';
  })();
  const avatar = v2String(row.AVATAR_URL);
  return {
    user_id: v2Number(row.USER_ID),
    username: v2String(row.USERNAME),
    display_name: v2String(row.DISPLAY_NAME),
    avatar_url: avatar ? normalizeStoragePublicUrl(avatar) : null,
    role: v2String(row.ROLE, 'member') as V2GroupRole,
    status,
    online_status: onlineStatus,
    last_seen_at:
      onlineStatus === 'hidden'
        ? null
        : v2DateString(row.LAST_SEEN_AT)
  };
}

function v2InPlaceholders(
  prefix: string,
  values: number[],
  binds: Record<string, number | string>
): string {
  return values
    .map((value, index) => {
      const key = `${prefix}_${index}`;
      binds[key] = value;
      return `:${key}`;
    })
    .join(', ');
}

async function v2ChatMembership(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  lock = false
): Promise<ChatMembership> {
  const row = await v2One(
    connection,
    `
    SELECT
      gm.group_id,
      gm.role,
      gm.status,
      CASE
        WHEN gm.role IN ('owner', 'admin', 'moderator') THEN 1
        ELSE 0
      END AS can_manage
    FROM n_group_members gm
    JOIN n_groups g ON g.group_id = gm.group_id
    WHERE gm.user_id = :user_id
      AND gm.group_id = :group_id
      AND gm.status IN ('active', 'muted')
      AND g.is_active = 1
      AND g.is_deleted = 0
    ${lock ? 'FOR UPDATE OF gm.role' : ''}
    `,
    { user_id: userId, group_id: groupId }
  );
  if (!row) v2Forbidden('无权访问该群组聊天');

  return {
    groupId,
    role: v2String(row.ROLE, 'member') as V2GroupRole,
    status: v2String(row.STATUS),
    canManage: v2Boolean(row.CAN_MANAGE)
  };
}

async function v2EnsureDefaultChatChannels(
  connection: oracledb.Connection,
  groupId: number,
  userId: number
): Promise<void> {
  const count = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_chat_channels
    WHERE group_id = :group_id
      AND is_deleted = 0
    `,
    { group_id: groupId }
  );
  if (count > 0) return;

  const group = await v2One(
    connection,
    `
    SELECT owner_id
    FROM n_groups
    WHERE group_id = :group_id
      AND is_active = 1
      AND is_deleted = 0
    FOR UPDATE
    `,
    { group_id: groupId }
  );
  if (!group) v2NotFound('群组不存在');

  const latestCount = await v2Count(
    connection,
    'SELECT COUNT(*) AS total FROM n_chat_channels WHERE group_id = :group_id AND is_deleted = 0',
    { group_id: groupId }
  );
  if (latestCount > 0) {
    await connection.rollback();
    return;
  }

  const ownerId = v2Number(group.OWNER_ID);
  const defaults: Array<{
    name: string;
    type: V2ChatChannelType;
    category: string;
    position: number;
  }> = [
    {
      name: '公告板',
      type: 'announcement',
      category: '公告',
      position: 10
    },
    {
      name: '综合讨论',
      type: 'text',
      category: '文字频道',
      position: 20
    }
  ];

  try {
    await v2ChatMembership(connection, userId, groupId);
    for (const item of defaults) {
    const channelId = await v2NextId(
      connection,
      'seq_chat_channel_id'
    );
    await v2Execute(
      connection,
      `
      INSERT INTO n_chat_channels (
        channel_id,
        group_id,
        name,
        channel_type,
        category,
        position,
        created_by
      ) VALUES (
        :channel_id,
        :group_id,
        :name,
        :channel_type,
        :category,
        :position,
        :created_by
      )
      `,
      {
        channel_id: channelId,
        group_id: groupId,
        name: item.name,
        channel_type: item.type,
        category: item.category,
        position: item.position,
        created_by: ownerId
      },
      false
    );
    }
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function v2RequireChatChannelAccess(
  connection: oracledb.Connection,
  userId: number,
  channelId: number,
  lockMembership = false
): Promise<ChatChannelAccess> {
  const row = await v2One(
    connection,
    `
    SELECT
      c.channel_id,
      c.group_id,
      c.channel_type,
      c.is_private,
      gm.role,
      gm.status,
      CASE
        WHEN gm.role IN ('owner', 'admin', 'moderator') THEN 1
        ELSE 0
      END AS can_manage
    FROM n_chat_channels c
    JOIN n_groups g ON g.group_id = c.group_id
    JOIN n_group_members gm
      ON gm.group_id = c.group_id
     AND gm.user_id = :user_id
    WHERE c.channel_id = :channel_id
      AND c.is_deleted = 0
      AND g.is_active = 1
      AND g.is_deleted = 0
      AND gm.status IN ('active', 'muted')
    ${lockMembership ? 'FOR UPDATE OF gm.role' : ''}
    `,
    { user_id: userId, channel_id: channelId }
  );
  if (!row) v2Forbidden('无权访问该聊天频道');

  const role = v2String(row.ROLE, 'member') as V2GroupRole;
  const canManage = v2Boolean(row.CAN_MANAGE);
  const isPrivate = v2Boolean(row.IS_PRIVATE);
  if (isPrivate && !canManage) {
    v2Forbidden('无权访问私密频道');
  }

  return {
    channelId,
    groupId: v2Number(row.GROUP_ID),
    role,
    status: v2String(row.STATUS),
    canManage,
    channelType: v2NormalizeChatChannelType(
      v2String(row.CHANNEL_TYPE)
    ),
    isPrivate
  };
}

function v2AssertCanManage(access: ChatMembership): void {
  if (!access.canManage) v2Forbidden('需要群组管理权限');
}

function v2AssertCanSend(access: ChatChannelAccess): void {
  if (access.status !== 'active' || (access.channelType === 'announcement' && !access.canManage)) {
    v2Forbidden('当前群组状态不允许发送消息');
  }
  if (
    access.channelType !== 'text' &&
    access.channelType !== 'announcement'
  ) {
    v2BadRequest('该频道类型暂不支持文字消息');
  }
}

async function v2PublishChatEvent(
  channelId: number,
  type: WSMessage['type'],
  data: Record<string, unknown>
): Promise<void> {
  const message: WSMessage = {
    type,
    room: v2ChatRoomId(channelId),
    data: {
      ...data,
      channel_id: channelId,
      server_id: WS_SERVER_ID
    },
    timestamp: Date.now()
  };

  sendWsToRoom(v2ChatRoomId(channelId), message);
  await publishMessage(v2ChatRedisChannel(channelId), message);
}

interface DirectConversationAccess {
  conversationId: number;
  participantUserId: number;
  userLowId: number;
  userHighId: number;
}

function v2DirectRedisChannel(userId: number): string {
  return `${REDIS_CHANNELS.USER_MESSAGE}${userId}`;
}

async function v2UserDisplayName(
  connection: oracledb.Connection,
  userId: number
): Promise<string> {
  const row = await v2One(
    connection,
    `
    SELECT COALESCE(display_name, username) AS name
    FROM n_users
    WHERE user_id = :user_id
    `,
    { user_id: userId }
  );
  return v2String(row?.NAME, '有人');
}

function v2NotificationPreview(content: string): string {
  const normalized = content.replace(/\s+/g, ' ').trim();
  if (normalized.length <= 80) return normalized;
  return `${normalized.slice(0, 80)}...`;
}

function v2DirectLastMessage(
  row: V2DbRecord
): V2DirectLastMessage | null {
  const messageId = v2Number(row.LAST_MESSAGE_ID);
  if (!messageId) return null;
  return {
    message_id: messageId,
    content: v2String(row.LAST_MESSAGE_CONTENT),
    author_name: v2String(row.LAST_MESSAGE_AUTHOR),
    created_at: v2DateString(row.LAST_MESSAGE_AT) || ''
  };
}

function v2MapDirectConversation(
  row: V2DbRecord
): V2DirectConversation {
  return {
    conversation_id: v2Number(row.CONVERSATION_ID),
    participant: v2MapPublicUser(row),
    unread_count: v2Number(row.UNREAD_COUNT),
    last_message: v2DirectLastMessage(row),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

function v2MapDirectMessage(
  row: V2DbRecord,
  viewerId: number
): V2DirectMessage {
  const authorId = v2Number(row.USER_ID);
  return {
    message_id: v2Number(row.MESSAGE_ID),
    conversation_id: v2Number(row.CONVERSATION_ID),
    content: v2String(row.CONTENT),
    author: v2MapPublicUser(row),
    is_deleted: v2Boolean(row.IS_DELETED),
    can_delete: authorId === viewerId,
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || '',
    edited_at: v2DateString(row.EDITED_AT),
    deleted_at: v2DateString(row.DELETED_AT)
  };
}

async function v2PublishDirectEvent(
  userIds: number[],
  type: WSMessage['type'],
  data: Record<string, unknown>
): Promise<void> {
  const message: WSMessage = {
    type,
    data: {
      ...data,
      server_id: WS_SERVER_ID
    },
    timestamp: Date.now()
  };

  await Promise.all(
    Array.from(new Set(userIds)).map(async userId => {
      sendWsToUser(userId, message);
      await publishMessage(v2DirectRedisChannel(userId), message);
    })
  );
}

async function v2AssertDirectTargetCanReceive(
  connection: oracledb.Connection,
  senderId: number,
  targetUserId: number
): Promise<void> {
  if (senderId === targetUserId) v2BadRequest('不能给自己发送私信');

  const row = await v2One(
    connection,
    `
    SELECT
      u.user_id,
      NVL(us.allow_dm_from_strangers, 0) AS allow_dm_from_strangers,
      fn_get_user_relationship(:sender_id, u.user_id) AS relation,
      (
        SELECT COUNT(*)
        FROM n_group_members gm_sender
        JOIN n_group_members gm_target
          ON gm_target.group_id = gm_sender.group_id
        JOIN n_groups g
          ON g.group_id = gm_sender.group_id
        WHERE gm_sender.user_id = :sender_id
          AND gm_target.user_id = u.user_id
          AND gm_sender.status IN ('active', 'muted')
          AND gm_target.status IN ('active', 'muted')
          AND g.is_active = 1
          AND g.is_deleted = 0
      ) AS shared_group_count
    FROM n_users u
    LEFT JOIN n_user_settings us ON us.user_id = u.user_id
    WHERE u.user_id = :target_user_id
      AND u.is_active = 1
    `,
    {
      sender_id: senderId,
      target_user_id: targetUserId
    }
  );
  if (!row) v2NotFound('用户不存在');

  const relation = v2String(row.RELATION, 'none');
  if (['blocking', 'blocked_by'].includes(relation)) {
    v2Forbidden('无法向该用户发送私信');
  }

  const acceptsStrangers = v2Boolean(
    row.ALLOW_DM_FROM_STRANGERS
  );
  const isTrusted =
    ['mutual_follow', 'followed_by'].includes(relation) ||
    v2Number(row.SHARED_GROUP_COUNT) > 0;
  if (!acceptsStrangers && !isTrusted) {
    v2Forbidden('对方不接收陌生人私信');
  }
}

export async function v2DeleteDirectMessage(
  event: H3Event, connection: oracledb.Connection, conversationId: number, messageId: number
) {
  const userId = v2Auth(event).userId;
  const conversation = {conversation_id: conversationId};
  const message = {...conversation, message_id: messageId};
  const actor = {user_id: userId};
  let recipient: number;
  try {
    const member = await v2One(connection, directDelete.lockConversation, {...conversation, ...actor});
    if (!member) {
      v2Forbidden('无权访问该私聊会话');
    }
    recipient = v2Number(member.RECIPIENT);
    if (!Number.isSafeInteger(recipient) || recipient <= 0 || recipient === userId) throw new Error('Invalid direct message recipient');
    const row = await v2One(connection, directDelete.lockMessage, message);
    if (!row) v2NotFound('私信不存在');
    if (v2Number(row.SENDER_ID) !== userId) v2Forbidden('无权删除该私信');
    if (v2Number(row.IS_DELETED) === 1) {
      await connection.rollback();
      return v2Ok(null, 'direct message deleted');
    }
    if (await v2Execute(connection, directDelete.deleteMessage, {...message, ...actor}, false) !== 1 ||
        await v2Execute(connection, directDelete.refreshConversation, conversation, false) !== 1) {
      throw new Error('Direct message delete affected an unexpected number of rows');
    }
    await v2Execute(connection, directDelete.redactNotification, {message_id: messageId, ...actor}, false);
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  try { await v2PublishDirectEvent([userId, recipient], 'direct_message_deleted', message); }
  catch { console.warn('[chat] direct deletion delivery unavailable'); }
  return v2Ok(null, 'direct message deleted');
}

export async function v2CanDeliverDirectMessage(
  connection: oracledb.Connection, userId: number, conversationId: number, messageId: number, deleted: boolean
): Promise<boolean> {
  return !!await v2One(connection, directRealtimeAccess.messageAccessSQL, {
    conversation_id: conversationId, message_id: messageId, user_id: userId, is_deleted: deleted ? 1 : 0
  });
}

async function v2RequireDirectConversationAccess(
  connection: oracledb.Connection,
  userId: number,
  conversationId: number,
  lock = false
): Promise<DirectConversationAccess> {
  const row = await v2One(
    connection,
    `
    SELECT conversation_id, user_low_id, user_high_id
    FROM n_direct_conversations
    WHERE conversation_id = :conversation_id
      AND is_deleted = 0
      AND (user_low_id = :user_id OR user_high_id = :user_id)
    ${lock ? 'FOR UPDATE' : ''}
    `,
    {
      conversation_id: conversationId,
      user_id: userId
    }
  );
  if (!row) v2Forbidden('无权访问该私聊会话');

  const userLowId = v2Number(row.USER_LOW_ID);
  const userHighId = v2Number(row.USER_HIGH_ID);
  return {
    conversationId,
    participantUserId: userLowId === userId ? userHighId : userLowId,
    userLowId,
    userHighId
  };
}

async function v2GetDirectConversation(
  connection: oracledb.Connection,
  viewerId: number,
  conversationId: number
): Promise<V2DirectConversation> {
  const row = await v2One(
    connection,
    `
    SELECT
      c.conversation_id,
      c.created_at,
      c.updated_at,
      p.user_id,
      p.username,
      p.avatar_url,
      p.display_name,
      p.bio,
      p.location,
      p.website,
      p.is_verified,
      p.followers_count,
      p.following_count,
      p.posts_count,
      p.likes_count,
      fn_get_user_relationship(:viewer_id, p.user_id) AS relation,
      lm.message_id AS last_message_id,
      lm.content AS last_message_content,
      COALESCE(lu.display_name, lu.username) AS last_message_author,
      lm.created_at AS last_message_at,
      (
        SELECT COUNT(*)
        FROM n_direct_messages dm
        LEFT JOIN n_direct_conversation_reads r
          ON r.conversation_id = dm.conversation_id
         AND r.user_id = :viewer_id
        WHERE dm.conversation_id = c.conversation_id
          AND dm.sender_id <> :viewer_id
          AND dm.is_deleted = 0
          AND dm.message_id > NVL(r.last_read_message_id, 0)
      ) AS unread_count
    FROM n_direct_conversations c
    JOIN v_user_profile_public p
      ON p.user_id = CASE
        WHEN c.user_low_id = :viewer_id THEN c.user_high_id
        ELSE c.user_low_id
      END
    LEFT JOIN n_direct_messages lm
      ON lm.message_id = c.last_message_id
     AND lm.is_deleted = 0
    LEFT JOIN n_users lu ON lu.user_id = lm.sender_id
    WHERE c.conversation_id = :conversation_id
      AND c.is_deleted = 0
      AND (c.user_low_id = :viewer_id OR c.user_high_id = :viewer_id)
    `,
    {
      viewer_id: viewerId,
      conversation_id: conversationId
    }
  );
  if (!row) v2NotFound('私聊会话不存在');
  return v2MapDirectConversation(row);
}

async function v2MarkDirectConversationRead(
  connection: oracledb.Connection,
  userId: number,
  conversationId: number,
  lastReadMessageId: number
): Promise<void> {
  await v2Execute(
    connection,
    `
    MERGE INTO n_direct_conversation_reads r
    USING (
      SELECT
        :conversation_id AS conversation_id,
        :user_id AS user_id,
        :last_read_message_id AS last_read_message_id
      FROM dual
    ) src
    ON (
      r.conversation_id = src.conversation_id
      AND r.user_id = src.user_id
    )
    WHEN MATCHED THEN
      UPDATE SET
        r.last_read_message_id = GREATEST(NVL(r.last_read_message_id, 0), src.last_read_message_id),
        r.last_read_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN
      INSERT (
        conversation_id,
        user_id,
        last_read_message_id,
        last_read_at
      ) VALUES (
        src.conversation_id,
        src.user_id,
        src.last_read_message_id,
        CURRENT_TIMESTAMP
      )
    `,
    {
      conversation_id: conversationId,
      user_id: userId,
      last_read_message_id: lastReadMessageId
    },
    false
  );
}

async function v2GetDirectMessage(
  connection: oracledb.Connection,
  viewerId: number,
  messageId: number
): Promise<V2DirectMessage> {
  const row = await v2One(
    connection,
    `
    SELECT
      dm.message_id,
      dm.conversation_id,
      dm.sender_id AS user_id,
      dm.content,
      dm.is_deleted,
      dm.created_at,
      dm.updated_at,
      dm.edited_at,
      dm.deleted_at,
      u.username,
      u.avatar_url,
      u.display_name,
      u.bio,
      u.location,
      u.website,
      u.is_verified,
      u.followers_count,
      u.following_count,
      u.posts_count,
      u.likes_count,
      fn_get_user_relationship(:viewer_id, u.user_id) AS relation
    FROM n_direct_messages dm
    JOIN v_user_profile_public u ON u.user_id = dm.sender_id
    JOIN n_direct_conversations c
      ON c.conversation_id = dm.conversation_id
    WHERE dm.message_id = :message_id
      AND dm.is_deleted = 0
      AND c.is_deleted = 0
      AND (c.user_low_id = :viewer_id OR c.user_high_id = :viewer_id)
    `,
    {
      viewer_id: viewerId,
      message_id: messageId
    }
  );
  if (!row) v2NotFound('私聊消息不存在');
  return v2MapDirectMessage(row, viewerId);
}

async function v2ChatMessageMediaMap(
  connection: oracledb.Connection,
  messageIds: number[]
): Promise<Map<number, V2MediaAsset[]>> {
  const result = new Map<number, V2MediaAsset[]>();
  if (messageIds.length === 0) return result;

  const binds: Record<string, number | string> = {};
  const placeholders = v2InPlaceholders(
    'message_id',
    messageIds,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT cmm.message_id, ma.*
    FROM n_chat_message_media cmm
    JOIN n_media_assets ma ON ma.media_id = cmm.media_id
    WHERE cmm.message_id IN (${placeholders})
    ORDER BY cmm.message_id, cmm.position ASC, cmm.chat_message_media_id ASC
    `,
    binds
  );

  for (const row of rows) {
    const messageId = v2Number(row.MESSAGE_ID);
    const media = v2MapMedia(row);
    const existing = result.get(messageId) ?? [];
    existing.push(media);
    result.set(messageId, existing);
  }
  return result;
}

async function v2ChatReactionMap(
  connection: oracledb.Connection,
  viewerId: number,
  messageIds: number[]
): Promise<Map<number, V2ChatReactionSummary[]>> {
  const result = new Map<number, V2ChatReactionSummary[]>();
  if (messageIds.length === 0) return result;

  const binds: Record<string, number | string> = {
    viewer_id: viewerId
  };
  const placeholders = v2InPlaceholders(
    'message_id',
    messageIds,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT
      message_id,
      emoji,
      COUNT(*) AS reaction_count,
      MAX(CASE WHEN user_id = :viewer_id THEN 1 ELSE 0 END) AS reacted_by_me
    FROM n_chat_message_reactions
    WHERE message_id IN (${placeholders})
    GROUP BY message_id, emoji
    ORDER BY message_id, reaction_count DESC, emoji ASC
    `,
    binds
  );

  for (const row of rows) {
    const messageId = v2Number(row.MESSAGE_ID);
    const existing = result.get(messageId) ?? [];
    existing.push({
      emoji: v2String(row.EMOJI),
      count: v2Number(row.REACTION_COUNT),
      reacted_by_me: v2Boolean(row.REACTED_BY_ME)
    });
    result.set(messageId, existing);
  }
  return result;
}

async function v2MapChatMessages(
  connection: oracledb.Connection,
  viewerId: number,
  rows: V2DbRecord[],
  accessByChannel = new Map<number, ChatChannelAccess>()
): Promise<V2ChatMessage[]> {
  const messageIds = rows.map(row => v2Number(row.MESSAGE_ID));
  const mediaByMessage = await v2ChatMessageMediaMap(
    connection,
    messageIds
  );
  const reactionsByMessage = await v2ChatReactionMap(
    connection,
    viewerId,
    messageIds
  );

  return rows.map(row => {
    const channelId = v2Number(row.CHANNEL_ID);
    const canManage =
      accessByChannel.get(channelId)?.canManage ??
      v2Boolean(row.CAN_MANAGE);
    const authorId = v2Number(row.USER_ID);
    const replyId = v2Number(row.REPLY_TO_MESSAGE_ID);

    return {
      message_id: v2Number(row.MESSAGE_ID),
      channel_id: channelId,
      group_id: v2Number(row.GROUP_ID),
      message_type: v2String(row.MESSAGE_TYPE, 'text') as
        | 'text'
        | 'system',
      content: v2String(row.CONTENT),
      author: v2MapPublicUser(row),
      reply_to: replyId
        ? {
            message_id: replyId,
            content: v2String(row.REPLY_CONTENT),
            author_name: v2String(row.REPLY_AUTHOR_NAME)
          }
        : null,
      media: mediaByMessage.get(v2Number(row.MESSAGE_ID)) ?? [],
      reactions:
        reactionsByMessage.get(v2Number(row.MESSAGE_ID)) ?? [],
      is_pinned: v2Boolean(row.IS_PINNED),
      is_deleted: v2Boolean(row.IS_DELETED),
      can_delete: canManage || authorId === viewerId,
      can_pin: canManage,
      created_at: v2DateString(row.CREATED_AT) || '',
      updated_at: v2DateString(row.UPDATED_AT) || '',
      edited_at: v2DateString(row.EDITED_AT),
      deleted_at: v2DateString(row.DELETED_AT)
    };
  });
}

async function v2GetChatMessageRows(
  connection: oracledb.Connection,
  viewerId: number,
  whereClause: string,
  binds: Record<string, number | string | null>
): Promise<V2DbRecord[]> {
  return await v2Rows(
    connection,
    `
    SELECT
      m.message_id,
      m.channel_id,
      m.group_id,
      m.author_id AS user_id,
      m.message_type,
      m.content,
      rm.message_id AS reply_to_message_id,
      m.is_pinned,
      m.is_deleted,
      m.created_at,
      m.updated_at,
      m.edited_at,
      m.deleted_at,
      u.username,
      u.avatar_url,
      u.display_name,
      u.bio,
      u.location,
      u.website,
      u.is_verified,
      u.followers_count,
      u.following_count,
      u.posts_count,
      u.likes_count,
      fn_get_user_relationship(:viewer_id, u.user_id) AS relation,
      rm.content AS reply_content,
      COALESCE(ru.display_name, ru.username) AS reply_author_name
    FROM n_chat_messages m
    JOIN v_user_profile_public u ON u.user_id = m.author_id
    LEFT JOIN n_chat_messages rm
      ON rm.message_id = m.reply_to_message_id
     AND rm.channel_id = m.channel_id AND rm.is_deleted = 0
    LEFT JOIN n_users ru ON ru.user_id = rm.author_id
    WHERE ${whereClause}
    ORDER BY m.created_at ASC, m.message_id ASC
    `,
    {
      ...binds,
      viewer_id: viewerId
    }
  );
}

async function v2GetChatMessage(
  connection: oracledb.Connection,
  viewerId: number,
  messageId: number,
  access?: ChatChannelAccess
): Promise<V2ChatMessage> {
  const rows = await v2GetChatMessageRows(
    connection,
    viewerId,
    'm.message_id = :message_id',
    { message_id: messageId }
  );
  const row = rows[0];
  if (!row) v2NotFound('聊天消息不存在');

  const channelId = v2Number(row.CHANNEL_ID);
  const accessMap = new Map<number, ChatChannelAccess>();
  if (access) accessMap.set(channelId, access);
  const messages = await v2MapChatMessages(
    connection,
    viewerId,
    [row],
    accessMap
  );
  const message = messages[0];
  if (!message) v2NotFound('聊天消息不存在');
  return message;
}

async function v2MarkChannelRead(
  connection: oracledb.Connection,
  userId: number,
  channelId: number,
  lastReadMessageId: number | null,
  alreadyLocked = false
): Promise<V2ChatReadStatusData> {
  if (!alreadyLocked) await v2LockChatChannelStatus(connection, userId, channelId);
  let targetMessageId: number | null = null;
  if (lastReadMessageId !== null) {
    const row = await v2One(
      connection,
      `
      SELECT message_id
      FROM n_chat_messages
      WHERE channel_id = :channel_id
        AND message_id = :message_id
        AND is_deleted = 0
      `,
      {
        channel_id: channelId,
        message_id: lastReadMessageId
      }
    );
    if (!row) {
      v2BadRequest('已读消息不存在或不属于该频道');
    }
    targetMessageId = v2Number(row.MESSAGE_ID);
  } else {
    const row = await v2One(
      connection,
      `
      SELECT MAX(message_id) AS message_id
      FROM n_chat_messages
      WHERE channel_id = :channel_id
        AND is_deleted = 0
      `,
      { channel_id: channelId }
    );
    targetMessageId = v2Number(row?.MESSAGE_ID) || null;
  }

  await v2Execute(
    connection,
    `
    MERGE INTO n_chat_channel_reads r
    USING (
      SELECT
        :channel_id AS channel_id,
        :user_id AS user_id,
        :last_read_message_id AS last_read_message_id
      FROM dual
    ) src
    ON (
      r.channel_id = src.channel_id
      AND r.user_id = src.user_id
    )
    WHEN MATCHED THEN
      UPDATE SET
        r.last_read_message_id = CASE
          WHEN NVL(src.last_read_message_id, 0) > NVL(r.last_read_message_id, 0)
          THEN src.last_read_message_id ELSE r.last_read_message_id END,
        r.last_read_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN
      INSERT (
        channel_id,
        user_id,
        last_read_message_id,
        last_read_at
      ) VALUES (
        src.channel_id,
        src.user_id,
        src.last_read_message_id,
        CURRENT_TIMESTAMP
      )
    `,
    {
      channel_id: channelId,
      user_id: userId,
      last_read_message_id: targetMessageId
    },
    false
  );

  const row = await v2One(
    connection,
    `
    SELECT r.last_read_message_id,
      (SELECT COUNT(*) FROM n_chat_messages m
       WHERE m.channel_id = r.channel_id AND m.is_deleted = 0
         AND m.message_id > NVL(r.last_read_message_id, 0)) AS unread_count
    FROM n_chat_channel_reads r
    WHERE r.channel_id = :channel_id AND r.user_id = :user_id
    `,
    {
      channel_id: channelId,
      user_id: userId
    }
  );
  if (!row) v2ServerError();
  await connection.commit();

  return {
    channel_id: channelId,
    last_read_message_id: v2Number(row.LAST_READ_MESSAGE_ID) || null,
    unread_count: v2Number(row.UNREAD_COUNT)
  };
}

export async function v2CanAccessChatChannel(
  connection: oracledb.Connection,
  userId: number,
  channelId: number
): Promise<boolean> {
  try {
    await v2RequireChatChannelAccess(
      connection,
      userId,
      channelId
    );
    return true;
  } catch {
    return false;
  }
}

export async function v2ListChatGroups(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2ChatGroup[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const rows = await v2Rows(
    connection,
    `
    WITH ranked AS (
      SELECT
        g.group_id,
        g.name,
        g.avatar_url,
        g.member_count,
        gm.role,
        gm.status,
        gm.joined_at,
        ROW_NUMBER() OVER (
          ORDER BY g.member_count DESC, g.created_at DESC, g.group_id DESC
        ) AS rn
      FROM n_group_members gm
      JOIN n_groups g ON g.group_id = gm.group_id
      WHERE gm.user_id = :user_id
        AND gm.status IN ('active', 'muted')
        AND g.is_active = 1
        AND g.is_deleted = 0
    )
    SELECT r.*, t.total,
        CASE
          WHEN r.role IN ('owner', 'admin', 'moderator') THEN 1
          ELSE 0
        END AS can_manage,
        (
          SELECT COUNT(*)
          FROM n_chat_channels c
          WHERE c.group_id = r.group_id
            AND c.is_deleted = 0
            AND (c.is_private = 0 OR r.role IN ('owner', 'admin', 'moderator'))
        ) AS channel_count,
        (
          SELECT COUNT(*)
          FROM n_chat_messages m
          JOIN n_chat_channels c ON c.channel_id = m.channel_id
          LEFT JOIN n_chat_channel_reads cr
            ON cr.channel_id = c.channel_id
           AND cr.user_id = :user_id
          WHERE c.group_id = r.group_id
            AND c.is_deleted = 0
            AND (c.is_private = 0 OR r.role IN ('owner', 'admin', 'moderator'))
            AND m.is_deleted = 0
            AND m.message_id > NVL(cr.last_read_message_id, 0)
        ) AS unread_count
    FROM (SELECT COUNT(*) AS total FROM ranked) t
    LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
    ORDER BY r.rn
    `,
    {
      user_id: auth.userId,
      start_row: page.start,
      end_row: page.end
    }
  );

  const groupsData: V2ChatGroup[] = rows.filter(row => row.GROUP_ID != null).map(row => ({
    group_id: v2Number(row.GROUP_ID),
    name: v2String(row.NAME),
    avatar_url: v2String(row.AVATAR_URL) || null,
    member_count: v2Number(row.MEMBER_COUNT),
    channel_count: v2Number(row.CHANNEL_COUNT),
    unread_count: v2Number(row.UNREAD_COUNT),
    membership: {
      is_member: true,
      role: v2String(row.ROLE) as V2GroupRole,
      status: v2String(row.STATUS),
      joined_at: v2DateString(row.JOINED_AT),
      can_manage: v2Boolean(row.CAN_MANAGE)
    }
  }));

  return v2Ok(
    groupsData,
    'success',
    v2PageMeta(page.page, page.page_size, v2Number(rows[0]?.TOTAL))
  );
}

async function v2ReadChatChannels(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  channelId?: number
): Promise<V2ChatChannel[]> {
  const rows = await v2Rows(
    connection,
    `
    SELECT
      c.channel_id,
      c.group_id,
      c.name,
      c.channel_type,
      c.category,
      c.position,
      c.is_private,
      c.created_at,
      c.updated_at,
      CASE WHEN gm.role IN ('owner', 'admin', 'moderator') THEN 1 ELSE 0 END AS can_manage,
      CASE WHEN cm.user_id IS NULL THEN 0 ELSE 1 END AS is_muted_by_me,
      (
        SELECT COUNT(*)
        FROM n_chat_messages m
        LEFT JOIN n_chat_channel_reads r
          ON r.channel_id = c.channel_id
         AND r.user_id = :user_id
        WHERE m.channel_id = c.channel_id
          AND m.is_deleted = 0
          AND m.message_id > NVL(r.last_read_message_id, 0)
      ) AS unread_count,
      lm.message_id AS last_message_id,
      lm.content AS last_message_content,
      lm.created_at AS last_message_at,
      COALESCE(lu.display_name, lu.username) AS last_message_author
    FROM n_chat_channels c
    JOIN n_groups g ON g.group_id = c.group_id AND g.is_active = 1 AND g.is_deleted = 0
    JOIN n_group_members gm
      ON gm.group_id = c.group_id AND gm.user_id = :user_id
     AND gm.status IN ('active', 'muted')
    LEFT JOIN n_chat_channel_mutes cm
      ON cm.channel_id = c.channel_id
     AND cm.user_id = :user_id
    LEFT JOIN n_chat_messages lm
      ON lm.message_id = c.last_message_id
     AND lm.channel_id = c.channel_id
     AND lm.is_deleted = 0
    LEFT JOIN n_users lu ON lu.user_id = lm.author_id
    WHERE c.group_id = :group_id
      AND c.is_deleted = 0
      AND (
        c.is_private = 0
        OR gm.role IN ('owner', 'admin', 'moderator')
      )
    ${channelId === undefined
      ? 'ORDER BY c.category ASC, c.position ASC, c.created_at ASC, c.channel_id ASC'
      : 'AND c.channel_id = :channel_id'}
    `,
    {
      user_id: userId,
      group_id: groupId,
      ...(channelId === undefined ? {} : { channel_id: channelId })
    }
  );

  return rows.map(row => v2MapChatChannel(row, v2Boolean(row.CAN_MANAGE)));
}

export async function v2ListChatChannels(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2ChatChannel[]>> {
  const { userId } = v2Auth(event);
  await v2ChatMembership(connection, userId, groupId);
  await v2EnsureDefaultChatChannels(connection, groupId, userId);
  const channels = await v2ReadChatChannels(connection, userId, groupId);
  if (channels.length === 0) await v2ChatMembership(connection, userId, groupId);
  return v2Ok(channels);
}

async function v2LockChatChannelManagement(
  connection: oracledb.Connection,
  userId: number,
  groupId: number
): Promise<void> {
  // Share the group lock with default-channel initialization and other channel writes.
  const group = await v2One(
    connection,
    `SELECT group_id FROM n_groups WHERE group_id = :group_id
     AND is_active = 1 AND is_deleted = 0 FOR UPDATE`,
    { group_id: groupId }
  );
  if (!group) v2Forbidden('无权访问该群组聊天');
  v2AssertCanManage(await v2ChatMembership(connection, userId, groupId, true));
}

async function v2ChatChannelBody(event: H3Event, optional = false): Promise<Record<string, unknown>> {
  const raw = await readRawBody(event);
  if (raw && Buffer.byteLength(raw, 'utf8') > 1024 * 1024) v2BadRequest('请求体格式错误');
  if (optional && !raw?.trim()) return {};
  if (!raw) v2BadRequest('请求体格式错误');
  let body: unknown;
  try { body = JSON.parse(raw); }
  catch { v2BadRequest('请求体格式错误'); }
  if (optional && body === null) return {};
  if (!body || typeof body !== 'object' || Array.isArray(body)) v2BadRequest('请求体格式错误');
  return body as Record<string, unknown>;
}

function v2ChatChannelName(value: unknown): string {
  const name = v2String(value).trim();
  if (!name || Buffer.byteLength(name, 'utf8') > 100) v2BadRequest('name 参数错误');
  return name;
}

function v2ChatChannelCategory(value: unknown): string {
  const category = v2String(value, '文字频道') || '文字频道';
  if (Buffer.byteLength(category, 'utf8') > 50) v2BadRequest('category 参数错误');
  return category;
}

async function v2CommitChatChannel(
  connection: oracledb.Connection,
  userId: number,
  groupId: number,
  channelId: number
): Promise<V2ChatChannel> {
  const [channel] = await v2ReadChatChannels(connection, userId, groupId, channelId);
  if (!channel) v2ServerError();
  await connection.commit();
  return channel;
}

export async function v2CreateChatChannel(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2ChatChannel>> {
  const { userId } = v2Auth(event);
  const body = await v2ChatChannelBody(event);
  const payload: V2CreateChatChannelPayload = {
    name: v2ChatChannelName(body.name),
    type: v2NormalizeChatChannelType(v2String(body.type, 'text')),
    category: v2ChatChannelCategory(body.category),
    is_private: v2Boolean(body.is_private)
  };

  await v2LockChatChannelManagement(connection, userId, groupId);
  const channelId = await v2NextId(connection, 'seq_chat_channel_id');
  if (!Number.isSafeInteger(channelId) || channelId <= 0) v2ServerError();
  const written = await v2Execute(
    connection,
    `INSERT INTO n_chat_channels (
      channel_id, group_id, name, channel_type, category, position, is_private, created_by
    ) VALUES (
      :channel_id, :group_id, :name, :channel_type, :category,
      (SELECT NVL(MAX(position), 0) + 10 FROM n_chat_channels WHERE group_id = :group_id),
      :is_private, :created_by
    )`,
    {
      channel_id: channelId,
      group_id: groupId,
      name: payload.name,
      channel_type: payload.type,
      category: payload.category || '文字频道',
      is_private: v2BoolNumber(payload.is_private),
      created_by: userId
    },
    false
  );
  if (written !== 1) v2ServerError();
  return v2Ok(await v2CommitChatChannel(connection, userId, groupId, channelId), 'chat channel created');
}

async function v2LockExistingChatChannel(
  connection: oracledb.Connection,
  userId: number,
  channelId: number
): Promise<ChatChannelAccess> {
  const access = await v2RequireChatChannelAccess(connection, userId, channelId);
  v2AssertCanManage(access);
  await v2LockChatChannelManagement(connection, userId, access.groupId);
  return v2RequireChatChannelAccess(connection, userId, channelId);
}

export async function v2UpdateChatChannel(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatChannel>> {
  const { userId } = v2Auth(event);
  const body = await v2ChatChannelBody(event);
  const clauses: string[] = [];
  const binds: Record<string, string | number> = { channel_id: channelId };

  if (Object.hasOwn(body, 'name')) {
    clauses.push('name = :name');
    binds.name = v2ChatChannelName(body.name);
  }
  if (Object.hasOwn(body, 'category')) {
    clauses.push('category = :category');
    binds.category = v2ChatChannelCategory(body.category);
  }
  if (Object.hasOwn(body, 'is_private')) {
    clauses.push('is_private = :is_private');
    binds.is_private = v2BoolNumber(body.is_private);
  }
  const access = await v2LockExistingChatChannel(connection, userId, channelId);
  if (clauses.length) {
    const written = await v2Execute(
      connection,
      `UPDATE n_chat_channels
      SET ${clauses.join(', ')}, updated_at = CURRENT_TIMESTAMP
      WHERE channel_id = :channel_id AND is_deleted = 0`,
      binds,
      false
    );
    if (written !== 1) v2ServerError();
  }
  return v2Ok(await v2CommitChatChannel(connection, userId, access.groupId, channelId), 'chat channel updated');
}

export async function v2DeleteChatChannel(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<null>> {
  const { userId } = v2Auth(event);
  await v2LockExistingChatChannel(connection, userId, channelId);
  const written = await v2Execute(
    connection,
    `UPDATE n_chat_channels SET is_deleted = 1, updated_at = CURRENT_TIMESTAMP
    WHERE channel_id = :channel_id AND is_deleted = 0`,
    { channel_id: channelId },
    false
  );
  if (written !== 1) v2ServerError();
  await connection.commit();
  return v2Null('chat channel deleted');
}

export async function v2ListChatMembers(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2ChatMember[]>> {
  const { userId } = v2Auth(event);
  const rows = await v2Rows(connection, `SELECT gm.user_id,gm.username,COALESCE(gm.nickname,gm.display_name,gm.username) AS display_name,
gm.avatar_url,gm.role,gm.status,
CASE WHEN NVL(us.show_online_status,1)=0 THEN 'hidden'
 WHEN EXISTS (SELECT 1 FROM n_auth_sessions s WHERE s.user_id=gm.user_id
 AND s.revoked_at IS NULL AND s.last_accessed_at>=CURRENT_TIMESTAMP-NUMTODSINTERVAL(90,'SECOND')) THEN 'online'
 ELSE 'offline' END AS online_status,
CASE WHEN NVL(us.show_online_status,1)=0 THEN NULL ELSE
 (SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=gm.user_id AND s.revoked_at IS NULL)
 END AS last_seen_at
FROM n_group_members viewer
JOIN n_groups g ON g.group_id=viewer.group_id AND g.is_active=1 AND g.is_deleted=0
LEFT JOIN v_group_member_details gm ON gm.group_id=g.group_id AND gm.status IN ('active','muted')
LEFT JOIN n_user_settings us ON us.user_id=gm.user_id
WHERE viewer.group_id=:group_id AND viewer.user_id=:user_id AND viewer.status IN ('active','muted')
ORDER BY CASE gm.role WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 WHEN 'moderator' THEN 3 ELSE 4 END,
gm.joined_at ASC,gm.user_id ASC`, { group_id: groupId, user_id: userId });
  if (rows.length === 0) v2Forbidden('无权访问该群组聊天');
  return v2Ok(rows.filter(row => row.USER_ID != null).map(v2MapChatMember));
}

export async function v2ListChatMessages(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatMessage[]>> {
  const auth = v2Auth(event);
  const access = await v2LockChatChannelStatus(
    connection,
    auth.userId,
    channelId
  );
  const page = v2Page(event);
  const q = v2QueryString(event, 'q').trim().toLowerCase();
  const qWhere = q
    ? 'AND LOWER(m.content) LIKE :q'
    : '';
  const binds: Record<string, number | string> = {
    channel_id: channelId
  };
  if (q) {
    binds.q = `%${q}%`;
  }

  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_chat_messages m
    JOIN v_user_profile_public u ON u.user_id = m.author_id
    WHERE m.channel_id = :channel_id
      AND m.is_deleted = 0
      ${qWhere}
    `,
    binds
  );

  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        inner_rows.*,
        ROW_NUMBER() OVER (
          ORDER BY inner_rows.created_at DESC, inner_rows.message_id DESC
        ) AS rn
      FROM (
        SELECT
          m.message_id,
          m.channel_id,
          m.group_id,
          m.author_id AS user_id,
          m.message_type,
          m.content,
          rm.message_id AS reply_to_message_id,
          m.is_pinned,
          m.is_deleted,
          m.created_at,
          m.updated_at,
          m.edited_at,
          m.deleted_at,
          u.username,
          u.avatar_url,
          u.display_name,
          u.bio,
          u.location,
          u.website,
          u.is_verified,
          u.followers_count,
          u.following_count,
          u.posts_count,
          u.likes_count,
          fn_get_user_relationship(:viewer_id, u.user_id) AS relation,
          rm.content AS reply_content,
          COALESCE(ru.display_name, ru.username) AS reply_author_name
        FROM n_chat_messages m
        JOIN v_user_profile_public u ON u.user_id = m.author_id
        LEFT JOIN n_chat_messages rm
          ON rm.message_id = m.reply_to_message_id
         AND rm.channel_id = m.channel_id AND rm.is_deleted = 0
        LEFT JOIN n_users ru ON ru.user_id = rm.author_id
        WHERE m.channel_id = :channel_id
          AND m.is_deleted = 0
          ${qWhere}
      ) inner_rows
    )
    WHERE rn BETWEEN :start_row AND :end_row
    ORDER BY created_at ASC, message_id ASC
    `,
    {
      ...binds,
      viewer_id: auth.userId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const accessMap = new Map<number, ChatChannelAccess>([
    [channelId, access]
  ]);
  const messages = await v2MapChatMessages(
    connection,
    auth.userId,
    rows,
    accessMap
  );

  if (!q && page.page === 1 && messages.length > 0) {
    await v2MarkChannelRead(
      connection,
      auth.userId,
      channelId,
      messages[messages.length - 1]?.message_id ?? null,
      true
    );
  } else {
    await connection.commit();
  }

  return v2Ok(
    messages,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateChatMessage(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatMessage>> {
  const auth = v2Auth(event);
  const body = await v2ChatChannelBody(event);
  if (body.content != null && typeof body.content !== 'string') v2BadRequest('content 参数错误');
  const content = typeof body.content === 'string' ? body.content.trim() : '';
  if (Buffer.byteLength(content, 'utf8') > 4000) v2BadRequest('content 超过最大长度');
  const isId = (value: unknown): value is number =>
    typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
  const mediaIds = body.media_ids === undefined ? [] : body.media_ids;
  if (!Array.isArray(mediaIds) || mediaIds.length > 32 ||
      !mediaIds.every(isId) || new Set(mediaIds).size !== mediaIds.length) {
    v2BadRequest('media_ids 参数错误');
  }
  if (!content && mediaIds.length === 0) v2BadRequest('消息内容或附件不能为空');

  const replyToMessageId = body.reply_to_message_id ?? null;
  if (replyToMessageId !== null && !isId(replyToMessageId)) v2BadRequest('reply_to_message_id 参数错误');
  let messageId: number;
  let message: V2ChatMessage;
  try {
    const access = await v2LockChatChannelStatus(connection, auth.userId, channelId);
    v2AssertCanSend(access);
    await requirePublishAccess(connection, auth.userId);
    if (replyToMessageId !== null) {
      const reply = await v2One(
        connection,
        `
        SELECT message_id
        FROM n_chat_messages
        WHERE message_id = :message_id
          AND channel_id = :channel_id
          AND is_deleted = 0
        FOR UPDATE
        `,
        {
          message_id: replyToMessageId,
          channel_id: channelId
        }
      );
      if (!reply) v2BadRequest('回复消息不存在');
    }

    for (const mediaId of [...mediaIds].sort((left, right) => left - right)) {
      const asset = await v2One(
        connection,
        `SELECT media_id, storage_key FROM n_media_assets WHERE media_id = :media_id
         AND owner_user_id = :owner_user_id AND status = 'ready'
         FOR UPDATE`,
        { media_id: mediaId, owner_user_id: auth.userId }
      );
      if (!asset || !await canBindMedia(connection, mediaId, asset.STORAGE_KEY, { scope: 'chat' })) {
        v2BadRequest('附件不存在或无权使用');
      }
    }

    messageId = await v2NextId(
      connection,
      'seq_chat_message_id'
    );
    if (!isId(messageId)) v2ServerError();
    const inserted = await v2Execute(
      connection,
      `
      INSERT INTO n_chat_messages (
        message_id,
        channel_id,
        group_id,
        author_id,
        message_type,
        content,
        reply_to_message_id
      ) VALUES (
        :message_id,
        :channel_id,
        :group_id,
        :author_id,
        'text',
        :content,
        :reply_to_message_id
      )
      `,
      {
        message_id: messageId,
        channel_id: channelId,
        group_id: access.groupId,
        author_id: auth.userId,
        content,
        reply_to_message_id: replyToMessageId
      },
      false
    );
    if (inserted !== 1) v2ServerError();

    for (const [index, mediaId] of mediaIds.entries()) {
      const linkId = await v2NextId(
        connection,
        'seq_chat_message_media_id'
      );
      const linked = await v2Execute(
        connection,
        `
        INSERT INTO n_chat_message_media (
          chat_message_media_id,
          message_id,
          media_id,
          position
        ) VALUES (
          :chat_message_media_id,
          :message_id,
          :media_id,
          :position
        )
        `,
        {
          chat_message_media_id: linkId,
          message_id: messageId,
          media_id: mediaId,
          position: index + 1
        },
        false
      );
      if (linked !== 1) v2ServerError();
    }

    const updated = await v2Execute(
      connection,
      `
      UPDATE n_chat_channels
      SET last_message_id = :message_id,
          last_message_at = CURRENT_TIMESTAMP,
          message_count = message_count + 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE channel_id = :channel_id AND is_deleted = 0
      `,
      {
        message_id: messageId,
        channel_id: channelId
      },
      false
    );
    if (updated !== 1) v2ServerError();
    message = await v2GetChatMessage(connection, auth.userId, messageId, access);
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }

  await v2PublishMessageMutation(channelId, 'chat_message', messageId, message);
  return v2Ok(message, 'chat message created');
}

type ChatMessageChange =
  | { kind: 'edit'; content: string }
  | { kind: 'delete' }
  | { kind: 'pin'; pinned: boolean }
  | { kind: 'reaction'; emoji: string; add: boolean };

async function v2PublishMessageMutation(
  channelId: number,
  type: 'chat_message' | 'chat_message_updated' | 'chat_message_deleted' | 'chat_reaction_updated',
  messageId: number,
  message: V2ChatMessage | null
): Promise<void> {
  try {
    await v2PublishChatEvent(channelId, type, message ? {
      viewer_neutral: true,
      message: {
        ...message,
        can_delete: false,
        can_pin: false,
        reactions: message.reactions.map(reaction => ({ ...reaction, reacted_by_me: false })),
        author: {
          ...message.author,
          relationship: { relation: 'none', is_self: false, is_following: false, is_blocked: false, is_blocking: false }
        }
      }
    } : { message_id: messageId });
  } catch {
    console.warn('chat message delivery unavailable');
  }
}

async function v2MutateChatMessage(
  connection: oracledb.Connection,
  userId: number,
  messageId: number,
  change: ChatMessageChange
): Promise<V2ChatMessage | null> {
  const row = await v2One(
    connection,
    'SELECT channel_id FROM n_chat_messages WHERE message_id = :message_id AND is_deleted = 0',
    { message_id: messageId }
  );
  if (!row) v2NotFound('聊天消息不存在');
  const channelId = v2Number(row.CHANNEL_ID);
  try {
    const access = await v2LockChatChannelStatus(connection, userId, channelId);
    const target = await v2One(
      connection,
      `SELECT author_id, message_type FROM n_chat_messages WHERE message_id = :message_id
       AND channel_id = :channel_id AND is_deleted = 0 FOR UPDATE`,
      { message_id: messageId, channel_id: channelId }
    );
    if (!target) v2NotFound('聊天消息不存在');
    if (change.kind === 'reaction') {
      await v2Execute(
        connection,
        change.add ? `MERGE INTO n_chat_message_reactions r
USING (SELECT :message_id AS message_id,:user_id AS user_id,:emoji AS emoji FROM dual) src
ON (r.message_id=src.message_id AND r.user_id=src.user_id AND r.emoji=src.emoji)
WHEN NOT MATCHED THEN INSERT (message_id,user_id,emoji) VALUES (src.message_id,src.user_id,src.emoji)`
          : `DELETE FROM n_chat_message_reactions WHERE message_id=:message_id AND user_id=:user_id AND emoji=:emoji`,
        { message_id: messageId, user_id: userId, emoji: change.emoji },
        false
      );
      const message = await v2GetChatMessage(connection, userId, messageId, access);
      await connection.commit();
      await v2PublishMessageMutation(channelId, 'chat_reaction_updated', messageId, message);
      return message;
    }
    const authorId = v2Number(target.AUTHOR_ID);
    const binds: Record<string, string | number> = { message_id: messageId };
    let fields: string;
    switch (change.kind) {
      case 'edit':
        if (target.MESSAGE_TYPE !== 'text') v2NotFound('聊天消息不存在');
        if (authorId !== userId || access.status !== 'active') v2Forbidden('无权操作该聊天消息');
        await requirePublishAccess(connection, userId);
        fields = 'content = :content, edited_at = CURRENT_TIMESTAMP';
        binds.content = change.content;
        break;
      case 'delete':
        if (authorId !== userId && !access.canManage) v2Forbidden('无权操作该聊天消息');
        fields = 'is_deleted = 1, deleted_by = :user_id, deleted_at = CURRENT_TIMESTAMP';
        binds.user_id = userId;
        break;
      case 'pin':
        if (!access.canManage) v2Forbidden('无权操作该聊天消息');
        fields = 'is_pinned = :is_pinned';
        binds.is_pinned = v2BoolNumber(change.pinned);
        break;
    }
    const affected = await v2Execute(
      connection,
      `UPDATE n_chat_messages SET ${fields}, updated_at = CURRENT_TIMESTAMP
       WHERE message_id = :message_id AND is_deleted = 0`,
      binds,
      false
    );
    if (affected !== 1) v2ServerError();

    let message: V2ChatMessage | null = null;
    if (change.kind === 'delete') {
      const updated = await v2Execute(
        connection,
        `UPDATE n_chat_channels c
         SET message_count = GREATEST(c.message_count - 1, 0),
             last_message_id = CASE WHEN c.last_message_id = :message_id THEN
               (SELECT MAX(m.message_id) FROM n_chat_messages m WHERE m.channel_id = c.channel_id AND m.is_deleted = 0)
               ELSE c.last_message_id END,
             last_message_at = CASE WHEN c.last_message_id = :message_id THEN
               (SELECT MAX(m.created_at) KEEP (DENSE_RANK LAST ORDER BY m.message_id)
                FROM n_chat_messages m WHERE m.channel_id = c.channel_id AND m.is_deleted = 0)
               ELSE c.last_message_at END,
             updated_at = CURRENT_TIMESTAMP
         WHERE c.channel_id = :channel_id AND c.is_deleted = 0`,
        { message_id: messageId, channel_id: channelId },
        false
      );
      if (updated !== 1) v2ServerError();
    } else {
      message = await v2GetChatMessage(connection, userId, messageId, access);
    }
    await connection.commit();
    await v2PublishMessageMutation(channelId, change.kind === 'delete'
      ? 'chat_message_deleted' : 'chat_message_updated', messageId, message);
    return message;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2UpdateChatMessage(
  event: H3Event, connection: oracledb.Connection, messageId: number
): Promise<V2Response<V2ChatMessage>> {
  const { userId } = v2Auth(event);
  const body = await v2ChatChannelBody(event);
  const content = typeof body.content === 'string' ? body.content.trim() : '';
  if (!content || Buffer.byteLength(content, 'utf8') > 4000) v2BadRequest('content 参数错误');
  const message = await v2MutateChatMessage(connection, userId, messageId, { kind: 'edit', content });
  if (!message) v2ServerError();
  return v2Ok(message, 'chat message updated');
}

export async function v2DeleteChatMessage(
  event: H3Event, connection: oracledb.Connection, messageId: number
): Promise<V2Response<null>> {
  const { userId } = v2Auth(event);
  await v2MutateChatMessage(connection, userId, messageId, { kind: 'delete' });
  return v2Null('chat message deleted');
}

export async function v2SetChatMessagePinStatus(
  event: H3Event, connection: oracledb.Connection, messageId: number
): Promise<V2Response<V2ChatMessage>> {
  const { userId } = v2Auth(event);
  const body = await v2ChatChannelBody(event);
  const message = await v2MutateChatMessage(connection, userId, messageId, { kind: 'pin', pinned: v2Boolean(body.is_pinned) });
  if (!message) v2ServerError();
  return v2Ok(message, 'chat message pin status updated');
}

async function v2SetChatReaction(
  event: H3Event, connection: oracledb.Connection, messageId: number, add: boolean
): Promise<V2Response<V2ChatMessage>> {
  const { userId } = v2Auth(event);
  const body = await v2ChatChannelBody(event);
  const emoji = typeof body.emoji === 'string' ? body.emoji.trim() : '';
  if (!emoji || emoji.length > 16 || Buffer.byteLength(emoji, 'utf8') > 32) v2BadRequest('emoji 参数错误');
  const message = await v2MutateChatMessage(connection, userId, messageId, { kind: 'reaction', emoji, add });
  if (!message) v2ServerError();
  return v2Ok(message, add ? 'chat reaction created' : 'chat reaction deleted');
}

export function v2CreateChatReaction(event: H3Event, connection: oracledb.Connection, messageId: number) {
  return v2SetChatReaction(event, connection, messageId, true);
}

export function v2DeleteChatReaction(event: H3Event, connection: oracledb.Connection, messageId: number) {
  return v2SetChatReaction(event, connection, messageId, false);
}

export async function v2SetChatReadStatus(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatReadStatusData>> {
  const auth = v2Auth(event);
  const body = await v2ChatChannelBody(event, true);
  const lastReadMessageId = body.last_read_message_id ?? null;
  if (lastReadMessageId !== null &&
      (typeof lastReadMessageId !== 'number' || !Number.isSafeInteger(lastReadMessageId) || lastReadMessageId <= 0)) {
    v2BadRequest('last_read_message_id 参数错误');
  }
  return v2Ok(
    await v2MarkChannelRead(
      connection,
      auth.userId,
      channelId,
      lastReadMessageId
    ),
    'chat read status updated'
  );
}

export async function v2SetChatChannelMuteStatus(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatChannelMuteData>> {
  const auth = v2Auth(event);
  const body = await v2ChatChannelBody(event);
  const muted = v2Boolean(body.is_muted);
  await v2LockChatChannelStatus(connection, auth.userId, channelId);

  if (muted) {
    await v2Execute(
      connection,
      `
      MERGE INTO n_chat_channel_mutes m
      USING (
        SELECT
          :channel_id AS channel_id,
          :user_id AS user_id
        FROM dual
      ) src
      ON (
        m.channel_id = src.channel_id
        AND m.user_id = src.user_id
      )
      WHEN NOT MATCHED THEN
        INSERT (channel_id, user_id)
        VALUES (src.channel_id, src.user_id)
      `,
      {
        channel_id: channelId,
        user_id: auth.userId
      },
      false
    );
  } else {
    await v2Execute(
      connection,
      `
      DELETE FROM n_chat_channel_mutes
      WHERE channel_id = :channel_id
        AND user_id = :user_id
      `,
      {
        channel_id: channelId,
        user_id: auth.userId
      },
      false
    );
  }

  await connection.commit();
  return v2Ok(
    {
      channel_id: channelId,
      is_muted: muted
    },
    'chat channel mute status updated'
  );
}

async function v2LockChatChannelStatus(
  connection: oracledb.Connection,
  userId: number,
  channelId: number
): Promise<ChatChannelAccess> {
  const { groupId } = await v2RequireChatChannelAccess(connection, userId, channelId);
  const group = await v2One(
    connection,
    `SELECT group_id FROM n_groups WHERE group_id = :group_id
     AND is_active = 1 AND is_deleted = 0 FOR UPDATE`,
    { group_id: groupId }
  );
  if (!group) v2Forbidden('无权访问该聊天频道');
  return v2RequireChatChannelAccess(connection, userId, channelId, true);
}

export async function v2ListDirectConversations(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2DirectConversation[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const raw = getQuery(event).conversation_id;
  const conversationId = raw === undefined ? 0 : typeof raw === 'string' &&
    /^[1-9][0-9]*$/.test(raw) && raw.trim() === raw ? Number(raw) : NaN;
  if (!Number.isSafeInteger(conversationId)) v2BadRequest('conversation_id 参数错误');

  const rows = await v2Rows(
    connection,
    `
    WITH ranked AS (
      SELECT
        inner_rows.*,
        ROW_NUMBER() OVER (
          ORDER BY NVL(inner_rows.last_message_at, inner_rows.updated_at) DESC,
                   inner_rows.conversation_id DESC
        ) AS rn
      FROM (
        SELECT
          c.conversation_id,
          c.created_at,
          c.updated_at,
          p.user_id,
          p.username,
          p.avatar_url,
          p.display_name,
          p.bio,
          p.location,
          p.website,
          p.is_verified,
          p.followers_count,
          p.following_count,
          p.posts_count,
          p.likes_count,
          fn_get_user_relationship(:viewer_id, p.user_id) AS relation,
          lm.message_id AS last_message_id,
          lm.content AS last_message_content,
          COALESCE(lu.display_name, lu.username) AS last_message_author,
          lm.created_at AS last_message_at,
          (
            SELECT COUNT(*)
            FROM n_direct_messages dm
            LEFT JOIN n_direct_conversation_reads r
              ON r.conversation_id = dm.conversation_id
             AND r.user_id = :viewer_id
            WHERE dm.conversation_id = c.conversation_id
              AND dm.sender_id <> :viewer_id
              AND dm.is_deleted = 0
              AND dm.message_id > NVL(r.last_read_message_id, 0)
          ) AS unread_count
        FROM n_direct_conversations c
        JOIN v_user_profile_public p
          ON p.user_id = CASE
            WHEN c.user_low_id = :viewer_id THEN c.user_high_id
            ELSE c.user_low_id
          END
        LEFT JOIN n_direct_messages lm
          ON lm.message_id = c.last_message_id
         AND lm.is_deleted = 0
        LEFT JOIN n_users lu ON lu.user_id = lm.sender_id
        WHERE c.is_deleted = 0
          AND (c.user_low_id = :viewer_id OR c.user_high_id = :viewer_id)
          AND (:conversation_id = 0 OR c.conversation_id = :conversation_id)
      ) inner_rows
    )
    SELECT r.*, t.total
    FROM (SELECT COUNT(*) AS total FROM ranked) t
    LEFT JOIN ranked r ON r.rn BETWEEN :start_row AND :end_row
    ORDER BY r.rn
    `,
    {
      viewer_id: auth.userId,
      conversation_id: conversationId,
      start_row: page.start,
      end_row: page.end
    }
  );

  return v2Ok(
    rows.filter(row => row.CONVERSATION_ID != null).map(v2MapDirectConversation),
    'success',
    v2PageMeta(page.page, page.page_size, v2Number(rows[0]?.TOTAL))
  );
}

export async function v2CreateDirectConversation(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2DirectConversation>> {
  const auth = v2Auth(event);
  const body =
    (await v2Body(event)) as Partial<V2CreateDirectConversationPayload>;
  const raw: unknown = body.target_user_id;
  const targetUserId = typeof raw === 'number' || (typeof raw === 'string' && /^[1-9][0-9]*$/.test(raw))
    ? Number(raw) : 0;
  if (!Number.isSafeInteger(targetUserId) || targetUserId <= 0) {
    v2BadRequest('target_user_id 参数错误');
  }
  await v2AssertDirectTargetCanReceive(
    connection,
    auth.userId,
    targetUserId
  );

  const userLowId = Math.min(auth.userId, targetUserId);
  const userHighId = Math.max(auth.userId, targetUserId);
  const readPair = () => v2One(
    connection,
    `
    SELECT conversation_id, is_deleted
    FROM n_direct_conversations
    WHERE user_low_id = :user_low_id
      AND user_high_id = :user_high_id
    `,
    {
      user_low_id: userLowId,
      user_high_id: userHighId
    }
  );

  const existing = await readPair();
  if (existing && v2Boolean(existing.IS_DELETED)) v2Conflict('私聊会话已删除');
  let conversationId = v2Number(existing?.CONVERSATION_ID);
  if (!conversationId) {
    conversationId = await v2NextId(
      connection,
      'seq_direct_conversation_id'
    );
    try {
      await v2Execute(
      connection,
      `
      INSERT INTO n_direct_conversations (
        conversation_id,
        user_low_id,
        user_high_id,
        created_by
      ) VALUES (
        :conversation_id,
        :user_low_id,
        :user_high_id,
        :created_by
      )
      `,
      {
        conversation_id: conversationId,
        user_low_id: userLowId,
        user_high_id: userHighId,
        created_by: auth.userId
      }
      );
    } catch (error) {
      if (typeof error !== 'object' || error === null || !('errorNum' in error) || error.errorNum !== 1) throw error;
      const winner = await readPair();
      if (!winner) throw error;
      if (v2Boolean(winner.IS_DELETED)) v2Conflict('私聊会话已删除');
      conversationId = v2Number(winner.CONVERSATION_ID);
    }
  }

  return v2Ok(
    await v2GetDirectConversation(
      connection,
      auth.userId,
      conversationId
    ),
    'direct conversation ready'
  );
}

export async function v2ListDirectMessages(
  event: H3Event,
  connection: oracledb.Connection,
  conversationId: number
): Promise<V2Response<V2DirectMessage[]>> {
  const auth = v2Auth(event);
  try {
    await v2RequireDirectConversationAccess(
      connection,
      auth.userId,
      conversationId,
      true
    );
    const page = v2Page(event);

    const total = await v2Count(
      connection,
      `
      SELECT COUNT(*) AS total
      FROM n_direct_messages
      WHERE conversation_id = :conversation_id
        AND is_deleted = 0
      `,
      { conversation_id: conversationId }
    );

    const rows = await v2Rows(
      connection,
      `
      SELECT *
      FROM (
        SELECT
          inner_rows.*,
          ROW_NUMBER() OVER (
            ORDER BY inner_rows.created_at DESC, inner_rows.message_id DESC
          ) AS rn
        FROM (
          SELECT
            dm.message_id,
            dm.conversation_id,
            dm.sender_id AS user_id,
            dm.content,
            dm.is_deleted,
            dm.created_at,
            dm.updated_at,
            dm.edited_at,
            dm.deleted_at,
            u.username,
            u.avatar_url,
            u.display_name,
            u.bio,
            u.location,
            u.website,
            u.is_verified,
            u.followers_count,
            u.following_count,
            u.posts_count,
            u.likes_count,
            fn_get_user_relationship(:viewer_id, u.user_id) AS relation
          FROM n_direct_messages dm
          JOIN v_user_profile_public u ON u.user_id = dm.sender_id
          WHERE dm.conversation_id = :conversation_id
            AND dm.is_deleted = 0
        ) inner_rows
      )
      WHERE rn BETWEEN :start_row AND :end_row
      ORDER BY created_at ASC, message_id ASC
      `,
      {
        viewer_id: auth.userId,
        conversation_id: conversationId,
        start_row: page.start,
        end_row: page.end
      }
    );
    const messages = rows.map(row =>
      v2MapDirectMessage(row, auth.userId)
    );

    const last = messages.at(-1);
    if (page.page === 1 && last) {
      await v2MarkDirectConversationRead(
        connection,
        auth.userId,
        conversationId,
        last.message_id
      );
    }

    await connection.commit();
    return v2Ok(
      messages,
      'success',
      v2PageMeta(page.page, page.page_size, total)
    );
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2CreateDirectMessage(
  event: H3Event,
  connection: oracledb.Connection,
  conversationId: number
): Promise<V2Response<V2DirectMessage>> {
  const auth = v2Auth(event);
  const body =
    (await v2Body(event)) as Partial<V2CreateDirectMessagePayload>;
  const content = v2RequiredString(body, 'content');
  if (Buffer.byteLength(content, 'utf8') > 4000) {
    v2BadRequest('content 超过最大长度');
  }

  let access: DirectConversationAccess;
  let message: V2DirectMessage;
  let notification: Awaited<ReturnType<typeof v2StoreNotification>>;

  try {
    access = await v2RequireDirectConversationAccess(connection, auth.userId, conversationId, true);
    await v2AssertDirectTargetCanReceive(connection, auth.userId, access.participantUserId);
    await requirePublishAccess(connection, auth.userId);
    const messageId = await v2NextId(connection, 'seq_direct_message_id');
    await v2Execute(
      connection,
      `
      INSERT INTO n_direct_messages (
        message_id,
        conversation_id,
        sender_id,
        content
      ) VALUES (
        :message_id,
        :conversation_id,
        :sender_id,
        :content
      )
      `,
      {
        message_id: messageId,
        conversation_id: conversationId,
        sender_id: auth.userId,
        content
      },
      false
    );

    await v2Execute(
      connection,
      `
      UPDATE n_direct_conversations
      SET last_message_id = :message_id,
          last_message_at = CURRENT_TIMESTAMP,
          message_count = message_count + 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE conversation_id = :conversation_id
      `,
      {
        message_id: messageId,
        conversation_id: conversationId
      },
      false
    );

    await v2MarkDirectConversationRead(connection, auth.userId, conversationId, messageId);
    message = await v2GetDirectMessage(connection, auth.userId, messageId);
    const actorName = await v2UserDisplayName(connection, auth.userId);
    notification = await v2StoreNotification(connection, {
      userId: access.participantUserId,
      actorId: auth.userId,
      type: 'direct_message',
      title: `${actorName} 给你发来私信`,
      message: v2NotificationPreview(content),
      resourceType: 'direct_message',
      resourceId: messageId,
      metadata: { conversation_id: conversationId, event: 'direct_message_created' }
    }, false);
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }

  const delivery = await Promise.allSettled([
    v2PublishDirectEvent([auth.userId, access.participantUserId], 'direct_message', {
      conversation_id: conversationId, direct_message: message
    }),
    notification ? v2DeliverStoredNotification(connection, notification) : Promise.resolve()
  ]);
  if (delivery.some(result => result.status === 'rejected')) {
    console.warn('[chat] direct message delivery unavailable');
  }
  return v2Ok(message, 'direct message created');
}
