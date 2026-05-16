import type { H3Event } from 'h3';
import { readBody } from 'h3';
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
  v2DateString,
  v2Execute,
  v2Forbidden,
  v2NextId,
  v2NotFound,
  v2Null,
  v2Number,
  v2NumberArray,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryString,
  v2RequiredNumber,
  v2RequiredString,
  v2Rows,
  v2String
} from '~/server/utils/v2';
import { v2MapMedia, v2MapPublicUser } from '~/server/models/v2';
import { v2CreateNotification } from './notifications';

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
  return {
    user_id: v2Number(row.USER_ID),
    username: v2String(row.USERNAME),
    display_name:
      v2String(row.NICKNAME) ||
      v2String(row.DISPLAY_NAME) ||
      v2String(row.USERNAME),
    avatar_url: v2String(row.AVATAR_URL) || null,
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

async function v2OptionalBody(
  event: H3Event
): Promise<Record<string, unknown>> {
  const body = await readBody<unknown>(event);
  if (body === undefined || body === null || body === '') {
    return {};
  }
  if (
    typeof body === 'object' &&
    !Array.isArray(body)
  ) {
    return body as Record<string, unknown>;
  }
  v2BadRequest('请求体必须是 JSON 对象');
}

async function v2ChatMembership(
  connection: oracledb.Connection,
  userId: number,
  groupId: number
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
  groupId: number
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
      AND is_deleted = 0
    `,
    { group_id: groupId }
  );
  if (!group) v2NotFound('群组不存在');

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
      }
    );
  }
}

async function v2RequireChatChannelAccess(
  connection: oracledb.Connection,
  userId: number,
  channelId: number
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
  if (access.status !== 'active') {
    v2Forbidden('当前群组状态不允许发送消息');
  }
  if (
    access.channelType !== 'text' &&
    access.channelType !== 'announcement'
  ) {
    v2BadRequest('该频道类型暂不支持文字消息');
  }
  if (
    access.channelType === 'announcement' &&
    !access.canManage
  ) {
    v2Forbidden('只有管理员可以在公告频道发言');
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

async function v2RequireDirectConversationAccess(
  connection: oracledb.Connection,
  userId: number,
  conversationId: number
): Promise<DirectConversationAccess> {
  const row = await v2One(
    connection,
    `
    SELECT conversation_id, user_low_id, user_high_id
    FROM n_direct_conversations
    WHERE conversation_id = :conversation_id
      AND is_deleted = 0
      AND (user_low_id = :user_id OR user_high_id = :user_id)
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
  lastReadMessageId: number | null
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
        r.last_read_message_id = src.last_read_message_id,
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
    }
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
    ORDER BY cmm.message_id, cmm.position ASC
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
      m.reply_to_message_id,
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
  lastReadMessageId: number | null
): Promise<V2ChatReadStatusData> {
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
        r.last_read_message_id = src.last_read_message_id,
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
    }
  );

  const unread = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_chat_messages
    WHERE channel_id = :channel_id
      AND is_deleted = 0
      AND message_id > NVL(:last_read_message_id, 0)
    `,
    {
      channel_id: channelId,
      last_read_message_id: targetMessageId
    }
  );

  return {
    channel_id: channelId,
    last_read_message_id: targetMessageId,
    unread_count: unread
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
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_group_members gm
    JOIN n_groups g ON g.group_id = gm.group_id
    WHERE gm.user_id = :user_id
      AND gm.status IN ('active', 'muted')
      AND g.is_active = 1
      AND g.is_deleted = 0
    `,
    { user_id: auth.userId }
  );

  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        g.group_id,
        g.name,
        g.avatar_url,
        g.member_count,
        gm.role,
        gm.status,
        gm.joined_at,
        CASE
          WHEN gm.role IN ('owner', 'admin', 'moderator') THEN 1
          ELSE 0
        END AS can_manage,
        (
          SELECT COUNT(*)
          FROM n_chat_channels c
          WHERE c.group_id = g.group_id
            AND c.is_deleted = 0
        ) AS channel_count,
        (
          SELECT COUNT(*)
          FROM n_chat_messages m
          JOIN n_chat_channels c ON c.channel_id = m.channel_id
          LEFT JOIN n_chat_channel_reads r
            ON r.channel_id = c.channel_id
           AND r.user_id = :user_id
          WHERE c.group_id = g.group_id
            AND c.is_deleted = 0
            AND m.is_deleted = 0
            AND m.message_id > NVL(r.last_read_message_id, 0)
        ) AS unread_count,
        ROW_NUMBER() OVER (
          ORDER BY g.member_count DESC, g.created_at DESC
        ) AS rn
      FROM n_group_members gm
      JOIN n_groups g ON g.group_id = gm.group_id
      WHERE gm.user_id = :user_id
        AND gm.status IN ('active', 'muted')
        AND g.is_active = 1
        AND g.is_deleted = 0
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      user_id: auth.userId,
      start_row: page.start,
      end_row: page.end
    }
  );

  for (const row of rows) {
    await v2EnsureDefaultChatChannels(
      connection,
      v2Number(row.GROUP_ID)
    );
  }

  const groupsData: V2ChatGroup[] = rows.map(row => ({
    group_id: v2Number(row.GROUP_ID),
    name: v2String(row.NAME),
    avatar_url: v2String(row.AVATAR_URL) || null,
    member_count: v2Number(row.MEMBER_COUNT),
    channel_count: Math.max(v2Number(row.CHANNEL_COUNT), 2),
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
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2ListChatChannels(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2ChatChannel[]>> {
  const auth = v2Auth(event);
  const membership = await v2ChatMembership(
    connection,
    auth.userId,
    groupId
  );
  await v2EnsureDefaultChatChannels(connection, groupId);

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
    LEFT JOIN n_chat_channel_mutes cm
      ON cm.channel_id = c.channel_id
     AND cm.user_id = :user_id
    LEFT JOIN n_chat_messages lm
      ON lm.message_id = c.last_message_id
    LEFT JOIN n_users lu ON lu.user_id = lm.author_id
    WHERE c.group_id = :group_id
      AND c.is_deleted = 0
      AND (
        c.is_private = 0
        OR :can_manage = 1
      )
    ORDER BY c.category ASC, c.position ASC, c.created_at ASC
    `,
    {
      user_id: auth.userId,
      group_id: groupId,
      can_manage: membership.canManage ? 1 : 0
    }
  );

  return v2Ok(
    rows.map(row => v2MapChatChannel(row, membership.canManage))
  );
}

export async function v2CreateChatChannel(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2ChatChannel>> {
  const auth = v2Auth(event);
  const membership = await v2ChatMembership(
    connection,
    auth.userId,
    groupId
  );
  v2AssertCanManage(membership);
  const body = await v2Body(event);
  const payload: V2CreateChatChannelPayload = {
    name: v2RequiredString(body, 'name'),
    type: v2NormalizeChatChannelType(
      v2String(body.type, 'text')
    ),
    category: v2String(body.category, '文字频道'),
    is_private: v2Boolean(body.is_private)
  };

  const position =
    v2Number(
      (
        await v2One(
          connection,
          `
          SELECT NVL(MAX(position), 0) + 10 AS next_position
          FROM n_chat_channels
          WHERE group_id = :group_id
          `,
          { group_id: groupId }
        )
      )?.NEXT_POSITION,
      10
    ) || 10;
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
      is_private,
      created_by
    ) VALUES (
      :channel_id,
      :group_id,
      :name,
      :channel_type,
      :category,
      :position,
      :is_private,
      :created_by
    )
    `,
    {
      channel_id: channelId,
      group_id: groupId,
      name: payload.name,
      channel_type: payload.type,
      category: payload.category || '文字频道',
      position,
      is_private: v2BoolNumber(payload.is_private),
      created_by: auth.userId
    }
  );

  const channels = await v2ListChatChannels(
    event,
    connection,
    groupId
  );
  const channel = channels.data.find(
    item => item.channel_id === channelId
  );
  if (!channel) v2NotFound('频道不存在');
  return v2Ok(channel, 'chat channel created');
}

export async function v2UpdateChatChannel(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatChannel>> {
  const auth = v2Auth(event);
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  v2AssertCanManage(access);
  const body = await v2Body(event);
  const clauses: string[] = [];
  const binds: Record<string, string | number> = {
    channel_id: channelId
  };

  if (Object.hasOwn(body, 'name')) {
    clauses.push('name = :name');
    binds.name = v2RequiredString(body, 'name');
  }
  if (Object.hasOwn(body, 'category')) {
    clauses.push('category = :category');
    binds.category = v2String(body.category, '文字频道');
  }
  if (Object.hasOwn(body, 'is_private')) {
    clauses.push('is_private = :is_private');
    binds.is_private = v2BoolNumber(body.is_private);
  }
  if (clauses.length) {
    await v2Execute(
      connection,
      `
      UPDATE n_chat_channels
      SET ${clauses.join(', ')},
          updated_at = CURRENT_TIMESTAMP
      WHERE channel_id = :channel_id
      `,
      binds
    );
  }

  const channels = await v2ListChatChannels(
    event,
    connection,
    access.groupId
  );
  const channel = channels.data.find(
    item => item.channel_id === channelId
  );
  if (!channel) v2NotFound('频道不存在');
  return v2Ok(channel, 'chat channel updated');
}

export async function v2DeleteChatChannel(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  v2AssertCanManage(access);

  await v2Execute(
    connection,
    `
    UPDATE n_chat_channels
    SET is_deleted = 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE channel_id = :channel_id
    `,
    { channel_id: channelId }
  );
  return v2Null('chat channel deleted');
}

export async function v2ListChatMembers(
  event: H3Event,
  connection: oracledb.Connection,
  groupId: number
): Promise<V2Response<V2ChatMember[]>> {
  const auth = v2Auth(event);
  await v2ChatMembership(connection, auth.userId, groupId);
  const rows = await v2Rows(
    connection,
    `
    SELECT
      gm.user_id,
      gm.username,
      gm.display_name,
      gm.avatar_url,
      gm.nickname,
      gm.role,
      gm.status,
      CASE
        WHEN NVL(us.show_online_status, 1) = 0 THEN 'hidden'
        WHEN EXISTS (
          SELECT 1
          FROM n_auth_sessions s
          WHERE s.user_id = gm.user_id
            AND s.revoked_at IS NULL
            AND s.last_accessed_at >= CURRENT_TIMESTAMP - NUMTODSINTERVAL(90, 'SECOND')
        ) THEN 'online'
        ELSE 'offline'
      END AS online_status,
      CASE
        WHEN NVL(us.show_online_status, 1) = 0 THEN NULL
        ELSE (
          SELECT MAX(s.last_accessed_at)
          FROM n_auth_sessions s
          WHERE s.user_id = gm.user_id
            AND s.revoked_at IS NULL
        )
      END AS last_seen_at
    FROM v_group_member_details gm
    LEFT JOIN n_user_settings us ON us.user_id = gm.user_id
    WHERE gm.group_id = :group_id
      AND gm.status IN ('active', 'muted')
    ORDER BY
      CASE gm.role
        WHEN 'owner' THEN 1
        WHEN 'admin' THEN 2
        WHEN 'moderator' THEN 3
        ELSE 4
      END,
      gm.joined_at ASC
    `,
    { group_id: groupId }
  );
  return v2Ok(rows.map(v2MapChatMember));
}

export async function v2ListChatMessages(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatMessage[]>> {
  const auth = v2Auth(event);
  const access = await v2RequireChatChannelAccess(
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
          m.reply_to_message_id,
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

  if (page.page === 1 && messages.length > 0) {
    await v2MarkChannelRead(
      connection,
      auth.userId,
      channelId,
      messages[messages.length - 1]?.message_id ?? null
    );
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
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  v2AssertCanSend(access);
  const body = await v2Body(event);
  const content = v2String(body.content).trim();
  const mediaIds = v2NumberArray(body.media_ids);
  if (!content && mediaIds.length === 0) {
    v2BadRequest('消息内容或附件不能为空');
  }

  let replyToMessageId: number | null = null;
  if (
    body.reply_to_message_id !== undefined &&
    body.reply_to_message_id !== null
  ) {
    replyToMessageId = v2RequiredNumber(
      body.reply_to_message_id,
      'reply_to_message_id'
    );
    const reply = await v2One(
      connection,
      `
      SELECT message_id
      FROM n_chat_messages
      WHERE message_id = :message_id
        AND channel_id = :channel_id
        AND is_deleted = 0
      `,
      {
        message_id: replyToMessageId,
        channel_id: channelId
      }
    );
    if (!reply) v2BadRequest('回复消息不存在');
  }

  if (mediaIds.length > 0) {
    const binds: Record<string, number | string> = {
      owner_user_id: auth.userId
    };
    const placeholders = v2InPlaceholders(
      'media_id',
      mediaIds,
      binds
    );
    const mediaCount = await v2Count(
      connection,
      `
      SELECT COUNT(*) AS total
      FROM n_media_assets
      WHERE media_id IN (${placeholders})
        AND owner_user_id = :owner_user_id
        AND status = 'ready'
      `,
      binds
    );
    if (mediaCount !== mediaIds.length) {
      v2BadRequest('附件不存在或无权使用');
    }
  }

  const messageId = await v2NextId(
    connection,
    'seq_chat_message_id'
  );
  try {
    await v2Execute(
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

    for (const [index, mediaId] of mediaIds.entries()) {
      const linkId = await v2NextId(
        connection,
        'seq_chat_message_media_id'
      );
      await v2Execute(
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
    }

    await v2Execute(
      connection,
      `
      UPDATE n_chat_channels
      SET last_message_id = :message_id,
          last_message_at = CURRENT_TIMESTAMP,
          message_count = message_count + 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE channel_id = :channel_id
      `,
      {
        message_id: messageId,
        channel_id: channelId
      },
      false
    );
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }

  const message = await v2GetChatMessage(
    connection,
    auth.userId,
    messageId,
    access
  );
  await v2PublishChatEvent(channelId, 'chat_message', {
    message
  });
  return v2Ok(message, 'chat message created');
}

export async function v2UpdateChatMessage(
  event: H3Event,
  connection: oracledb.Connection,
  messageId: number
): Promise<V2Response<V2ChatMessage>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const content = v2RequiredString(body, 'content');
  const row = await v2One(
    connection,
    `
    SELECT
      message_id,
      channel_id,
      author_id
    FROM n_chat_messages
    WHERE message_id = :message_id
      AND is_deleted = 0
      AND message_type = 'text'
    `,
    { message_id: messageId }
  );
  if (!row) v2NotFound('聊天消息不存在');
  const channelId = v2Number(row.CHANNEL_ID);
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  if (v2Number(row.AUTHOR_ID) !== auth.userId) {
    v2Forbidden('只能编辑自己的消息');
  }
  if (access.status !== 'active') {
    v2Forbidden('当前群组状态不允许编辑消息');
  }

  await v2Execute(
    connection,
    `
    UPDATE n_chat_messages
    SET content = :content,
        edited_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE message_id = :message_id
    `,
    {
      content,
      message_id: messageId
    }
  );

  const message = await v2GetChatMessage(
    connection,
    auth.userId,
    messageId,
    access
  );
  await v2PublishChatEvent(channelId, 'chat_message_updated', {
    message
  });
  return v2Ok(message, 'chat message updated');
}

export async function v2DeleteChatMessage(
  event: H3Event,
  connection: oracledb.Connection,
  messageId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT
      m.message_id,
      m.channel_id,
      m.author_id
    FROM n_chat_messages m
    WHERE m.message_id = :message_id
      AND m.is_deleted = 0
    `,
    { message_id: messageId }
  );
  if (!row) v2NotFound('聊天消息不存在');
  const channelId = v2Number(row.CHANNEL_ID);
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  const authorId = v2Number(row.AUTHOR_ID);
  if (authorId !== auth.userId && !access.canManage) {
    v2Forbidden('无权删除该消息');
  }

  await v2Execute(
    connection,
    `
    UPDATE n_chat_messages
    SET is_deleted = 1,
        deleted_by = :deleted_by,
        deleted_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE message_id = :message_id
    `,
    {
      deleted_by: auth.userId,
      message_id: messageId
    }
  );

  await v2Execute(
    connection,
    `
    UPDATE n_chat_channels c
    SET message_count = GREATEST(message_count - 1, 0),
        last_message_id = CASE
          WHEN c.last_message_id = :message_id THEN (
            SELECT MAX(m.message_id)
            FROM n_chat_messages m
            WHERE m.channel_id = :channel_id
              AND m.is_deleted = 0
          )
          ELSE c.last_message_id
        END,
        last_message_at = CASE
          WHEN c.last_message_id = :message_id THEN (
            SELECT MAX(m.created_at) KEEP (
              DENSE_RANK LAST ORDER BY m.message_id
            )
            FROM n_chat_messages m
            WHERE m.channel_id = :channel_id
              AND m.is_deleted = 0
          )
          ELSE c.last_message_at
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE c.channel_id = :channel_id
    `,
    {
      message_id: messageId,
      channel_id: channelId
    }
  );

  await v2PublishChatEvent(channelId, 'chat_message_deleted', {
    message_id: messageId
  });
  return v2Null('chat message deleted');
}

export async function v2SetChatMessagePinStatus(
  event: H3Event,
  connection: oracledb.Connection,
  messageId: number
): Promise<V2Response<V2ChatMessage>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const row = await v2One(
    connection,
    `
    SELECT channel_id
    FROM n_chat_messages
    WHERE message_id = :message_id
      AND is_deleted = 0
    `,
    { message_id: messageId }
  );
  if (!row) v2NotFound('聊天消息不存在');
  const channelId = v2Number(row.CHANNEL_ID);
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  v2AssertCanManage(access);

  await v2Execute(
    connection,
    `
    UPDATE n_chat_messages
    SET is_pinned = :is_pinned,
        updated_at = CURRENT_TIMESTAMP
    WHERE message_id = :message_id
    `,
    {
      is_pinned: v2BoolNumber(body.is_pinned),
      message_id: messageId
    }
  );

  const message = await v2GetChatMessage(
    connection,
    auth.userId,
    messageId,
    access
  );
  await v2PublishChatEvent(channelId, 'chat_message_updated', {
    message
  });
  return v2Ok(message, 'chat message pin status updated');
}

export async function v2CreateChatReaction(
  event: H3Event,
  connection: oracledb.Connection,
  messageId: number
): Promise<V2Response<V2ChatMessage>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const emoji = v2RequiredString(body, 'emoji');
  if (emoji.length > 16) v2BadRequest('emoji 参数过长');

  const row = await v2One(
    connection,
    `
    SELECT channel_id
    FROM n_chat_messages
    WHERE message_id = :message_id
      AND is_deleted = 0
    `,
    { message_id: messageId }
  );
  if (!row) v2NotFound('聊天消息不存在');
  const channelId = v2Number(row.CHANNEL_ID);
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );

  await v2Execute(
    connection,
    `
    MERGE INTO n_chat_message_reactions r
    USING (
      SELECT
        :message_id AS message_id,
        :user_id AS user_id,
        :emoji AS emoji
      FROM dual
    ) src
    ON (
      r.message_id = src.message_id
      AND r.user_id = src.user_id
      AND r.emoji = src.emoji
    )
    WHEN NOT MATCHED THEN
      INSERT (message_id, user_id, emoji)
      VALUES (src.message_id, src.user_id, src.emoji)
    `,
    {
      message_id: messageId,
      user_id: auth.userId,
      emoji
    }
  );

  const message = await v2GetChatMessage(
    connection,
    auth.userId,
    messageId,
    access
  );
  await v2PublishChatEvent(channelId, 'chat_reaction_updated', {
    message
  });
  return v2Ok(message, 'chat reaction created');
}

export async function v2DeleteChatReaction(
  event: H3Event,
  connection: oracledb.Connection,
  messageId: number
): Promise<V2Response<V2ChatMessage>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const emoji = v2RequiredString(body, 'emoji');

  const row = await v2One(
    connection,
    `
    SELECT channel_id
    FROM n_chat_messages
    WHERE message_id = :message_id
      AND is_deleted = 0
    `,
    { message_id: messageId }
  );
  if (!row) v2NotFound('聊天消息不存在');
  const channelId = v2Number(row.CHANNEL_ID);
  const access = await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );

  await v2Execute(
    connection,
    `
    DELETE FROM n_chat_message_reactions
    WHERE message_id = :message_id
      AND user_id = :user_id
      AND emoji = :emoji
    `,
    {
      message_id: messageId,
      user_id: auth.userId,
      emoji
    }
  );

  const message = await v2GetChatMessage(
    connection,
    auth.userId,
    messageId,
    access
  );
  await v2PublishChatEvent(channelId, 'chat_reaction_updated', {
    message
  });
  return v2Ok(message, 'chat reaction deleted');
}

export async function v2SetChatReadStatus(
  event: H3Event,
  connection: oracledb.Connection,
  channelId: number
): Promise<V2Response<V2ChatReadStatusData>> {
  const auth = v2Auth(event);
  await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  const body = await v2OptionalBody(event);
  const lastReadMessageId =
    body.last_read_message_id === undefined ||
    body.last_read_message_id === null
      ? null
      : v2RequiredNumber(
          body.last_read_message_id,
          'last_read_message_id'
        );
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
  await v2RequireChatChannelAccess(
    connection,
    auth.userId,
    channelId
  );
  const body = await v2Body(event);
  const muted = v2Boolean(body.is_muted);

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
      }
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
      }
    );
  }

  return v2Ok(
    {
      channel_id: channelId,
      is_muted: muted
    },
    'chat channel mute status updated'
  );
}

export async function v2ListDirectConversations(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2DirectConversation[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);

  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_direct_conversations
    WHERE is_deleted = 0
      AND (user_low_id = :viewer_id OR user_high_id = :viewer_id)
    `,
    { viewer_id: auth.userId }
  );

  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
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
      ) inner_rows
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      viewer_id: auth.userId,
      start_row: page.start,
      end_row: page.end
    }
  );

  return v2Ok(
    rows.map(v2MapDirectConversation),
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateDirectConversation(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2DirectConversation>> {
  const auth = v2Auth(event);
  const body =
    (await v2Body(event)) as Partial<V2CreateDirectConversationPayload>;
  const targetUserId = v2RequiredNumber(
    body.target_user_id,
    'target_user_id'
  );
  await v2AssertDirectTargetCanReceive(
    connection,
    auth.userId,
    targetUserId
  );

  const userLowId = Math.min(auth.userId, targetUserId);
  const userHighId = Math.max(auth.userId, targetUserId);
  const existing = await v2One(
    connection,
    `
    SELECT conversation_id
    FROM n_direct_conversations
    WHERE user_low_id = :user_low_id
      AND user_high_id = :user_high_id
      AND is_deleted = 0
    `,
    {
      user_low_id: userLowId,
      user_high_id: userHighId
    }
  );

  let conversationId = v2Number(existing?.CONVERSATION_ID);
  if (!conversationId) {
    conversationId = await v2NextId(
      connection,
      'seq_direct_conversation_id'
    );
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
  await v2RequireDirectConversationAccess(
    connection,
    auth.userId,
    conversationId
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

  if (page.page === 1 && messages.length > 0) {
    await v2MarkDirectConversationRead(
      connection,
      auth.userId,
      conversationId,
      messages[messages.length - 1]?.message_id ?? null
    );
  }

  return v2Ok(
    messages,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateDirectMessage(
  event: H3Event,
  connection: oracledb.Connection,
  conversationId: number
): Promise<V2Response<V2DirectMessage>> {
  const auth = v2Auth(event);
  const access = await v2RequireDirectConversationAccess(
    connection,
    auth.userId,
    conversationId
  );
  await v2AssertDirectTargetCanReceive(
    connection,
    auth.userId,
    access.participantUserId
  );

  const body =
    (await v2Body(event)) as Partial<V2CreateDirectMessagePayload>;
  const content = v2RequiredString(body, 'content');
  const messageId = await v2NextId(
    connection,
    'seq_direct_message_id'
  );

  try {
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

    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }

  await v2MarkDirectConversationRead(
    connection,
    auth.userId,
    conversationId,
    messageId
  );

  const message = await v2GetDirectMessage(
    connection,
    auth.userId,
    messageId
  );
  const actorName = await v2UserDisplayName(connection, auth.userId);
  await v2CreateNotification(connection, {
    userId: access.participantUserId,
    actorId: auth.userId,
    type: 'direct_message',
    title: `${actorName} 给你发来私信`,
    message: v2NotificationPreview(content),
    resourceType: 'direct_message',
    resourceId: messageId,
    metadata: {
      conversation_id: conversationId,
      event: 'direct_message_created'
    }
  });
  await v2PublishDirectEvent(
    [auth.userId, access.participantUserId],
    'direct_message',
    {
      conversation_id: conversationId,
      direct_message: message
    }
  );
  return v2Ok(message, 'direct message created');
}
