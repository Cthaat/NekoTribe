import { confirmedChannelMute } from '@/utils/chat-channel-mute';
import {
  toV2PagedResult,
  v2Request,
  v2RequestData,
  type V2QueryParams
} from './client';
import type {
  V2ChatChannel,
  V2ChatChannelMuteData,
  V2ChatGroup,
  V2ChatMember,
  V2ChatMessage,
  V2ChatMessagePinPayload,
  V2ChatReadStatusData,
  V2ChatReactionPayload,
  V2CreateChatChannelPayload,
  V2CreateChatMessagePayload,
  V2CreateDirectConversationPayload,
  V2CreateDirectMessagePayload,
  V2DirectConversation,
  V2DirectMessage,
  V2PagedResult,
  V2UpdateChatChannelPayload,
  V2ApiResponse,
  V2UpdateChatMessagePayload
} from '@/types/v2';

export interface V2ChatPageQuery extends V2QueryParams {
  page?: number;
  page_size?: number;
}

export interface V2ChatMessageListQuery
  extends V2ChatPageQuery {
  q?: string;
}

export async function v2ListChatGroups(
  query: V2ChatPageQuery = {}
): Promise<V2PagedResult<V2ChatGroup>> {
  const response = await v2Request<
    V2ChatGroup[],
    undefined,
    V2ChatPageQuery
  >('/api/v2/chat/groups', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ListChatChannels(
  groupId: number
): Promise<V2ChatChannel[]> {
  const channels = await v2RequestData<V2ChatChannel[]>(
    `/api/v2/chat/groups/${groupId}/channels`,
    { method: 'GET' }
  );
  if (!Array.isArray(channels)) throw new Error('Invalid chat channel list');
  const ids = new Set<number>();
  for (const channel of channels) {
    if (!channel || channel.group_id !== groupId ||
        !Number.isSafeInteger(channel.channel_id) || channel.channel_id <= 0 ||
        ids.has(channel.channel_id)) {
      throw new Error('Invalid chat channel list');
    }
    ids.add(channel.channel_id);
  }
  return channels;
}

export async function v2CreateChatChannel(
  groupId: number,
  payload: V2CreateChatChannelPayload
): Promise<V2ChatChannel> {
  const channel = await v2RequestData<
    V2ChatChannel,
    V2CreateChatChannelPayload
  >(`/api/v2/chat/groups/${groupId}/channels`, {
    method: 'POST',
    body: payload
  });
  if (!channel || channel.group_id !== groupId ||
      !Number.isSafeInteger(channel.channel_id) || channel.channel_id <= 0) {
    throw new Error('Invalid chat channel create response');
  }
  return channel;
}

export async function v2UpdateChatChannel(
  channelId: number,
  payload: V2UpdateChatChannelPayload
): Promise<V2ChatChannel> {
  const channel = await v2RequestData<
    V2ChatChannel,
    V2UpdateChatChannelPayload
  >(`/api/v2/chat/channels/${channelId}`, {
    method: 'PATCH',
    body: payload
  });
  if (!channel || channel.channel_id !== channelId ||
      !Number.isSafeInteger(channel.group_id) || channel.group_id <= 0) {
    throw new Error('Invalid chat channel update response');
  }
  return channel;
}

export async function v2DeleteChatChannel(
  channelId: number
): Promise<void> {
  const response = await v2Request<null>(
    `/api/v2/chat/channels/${channelId}`,
    { method: 'DELETE' }
  );
  if (!response || response.code !== 200 || response.message !== 'chat channel deleted' ||
      response.data !== null || response.meta !== null) {
    throw new Error('Invalid chat channel delete response');
  }
}

export async function v2ListChatMembers(
  groupId: number
): Promise<V2ChatMember[]> {
  return await v2RequestData<V2ChatMember[]>(
    `/api/v2/chat/groups/${groupId}/members`,
    { method: 'GET' }
  );
}

export async function v2ListChatMessages(
  channelId: number,
  query: V2ChatMessageListQuery = {}
): Promise<V2PagedResult<V2ChatMessage>> {
  const response = await v2Request<
    V2ChatMessage[],
    undefined,
    V2ChatMessageListQuery
  >(`/api/v2/chat/channels/${channelId}/messages`, {
    method: 'GET',
    query
  });
  const invalid = new Error('Invalid channel message history response');
  requireChatPage(response, query, invalid);
  const ids = new Set<number>();
  for (const message of response.data) {
    if (!message || message.channel_id !== channelId ||
        !Number.isSafeInteger(message.message_id) || message.message_id <= 0 ||
        !Number.isSafeInteger(message.group_id) || message.group_id <= 0 ||
        message.is_deleted !== false || ids.has(message.message_id)) {
      throw invalid;
    }
    ids.add(message.message_id);
  }
  return toV2PagedResult(response);
}

export async function v2CreateChatMessage(
  channelId: number,
  payload: V2CreateChatMessagePayload
): Promise<V2ChatMessage> {
  return await v2RequestData<
    V2ChatMessage,
    V2CreateChatMessagePayload
  >(`/api/v2/chat/channels/${channelId}/messages`, {
    method: 'POST',
    body: payload
  });
}

export async function v2DeleteChatMessage(
  messageId: number
): Promise<void> {
  const response = await v2Request<null>(
    `/api/v2/chat/messages/${messageId}`,
    { method: 'DELETE' }
  );
  if (!response || response.code !== 200 || response.message !== 'chat message deleted' ||
      response.data !== null || response.meta !== null) {
    throw new Error('Invalid chat message delete response');
  }
}

export async function v2UpdateChatMessage(
  messageId: number,
  payload: V2UpdateChatMessagePayload
): Promise<V2ChatMessage> {
  const message = await v2RequestData<
    V2ChatMessage,
    V2UpdateChatMessagePayload
  >(`/api/v2/chat/messages/${messageId}`, {
    method: 'PATCH',
    body: payload
  });
  if (!validChatMessageMutation(messageId, message) ||
      message.content !== payload.content.trim()) {
    throw new Error('Invalid chat message edit response');
  }
  return message;
}

export async function v2SetChatMessagePinStatus(
  messageId: number,
  payload: V2ChatMessagePinPayload
): Promise<V2ChatMessage> {
  const message = await v2RequestData<
    V2ChatMessage,
    V2ChatMessagePinPayload
  >(`/api/v2/chat/messages/${messageId}/pin-status`, {
    method: 'PUT',
    body: payload
  });
  if (!validChatMessageMutation(messageId, message) || message.is_pinned !== payload.is_pinned) {
    throw new Error('Invalid chat message pin response');
  }
  return message;
}

function validChatMessageMutation(messageId: number, message: V2ChatMessage | null): boolean {
  return !!message && message.message_id === messageId && message.is_deleted === false &&
    Number.isSafeInteger(message.channel_id) && message.channel_id > 0 &&
    Number.isSafeInteger(message.group_id) && message.group_id > 0;
}

export async function v2CreateChatReaction(
  messageId: number,
  payload: V2ChatReactionPayload
): Promise<V2ChatMessage> {
  return await setChatReaction(messageId, payload, true);
}

export async function v2DeleteChatReaction(
  messageId: number,
  payload: V2ChatReactionPayload
): Promise<V2ChatMessage> {
  return await setChatReaction(messageId, payload, false);
}

async function setChatReaction(
  messageId: number, payload: V2ChatReactionPayload, reacted: boolean
): Promise<V2ChatMessage> {
  const message = await v2RequestData<
    V2ChatMessage,
    V2ChatReactionPayload
  >(`/api/v2/chat/messages/${messageId}/reactions`, {
    method: reacted ? 'POST' : 'DELETE',
    body: payload
  });
  if (!validChatMessageMutation(messageId, message) || !Array.isArray(message.reactions)) {
    throw new Error('Invalid chat reaction response');
  }
  const emojis = new Set<string>();
  for (const reaction of message.reactions) {
    if (!reaction || typeof reaction.emoji !== 'string' || !reaction.emoji ||
        emojis.has(reaction.emoji) || !Number.isSafeInteger(reaction.count) || reaction.count <= 0 ||
        typeof reaction.reacted_by_me !== 'boolean') {
      throw new Error('Invalid chat reaction response');
    }
    emojis.add(reaction.emoji);
  }
  const target = message.reactions.find(reaction => reaction.emoji === payload.emoji.trim());
  if ((target?.reacted_by_me ?? false) !== reacted) throw new Error('Invalid chat reaction response');
  return message;
}

export async function v2SetChatReadStatus(
  channelId: number,
  lastReadMessageId?: number | null
): Promise<V2ChatReadStatusData> {
  return await v2RequestData<
    V2ChatReadStatusData,
    { last_read_message_id?: number | null }
  >(`/api/v2/chat/channels/${channelId}/read-status`, {
    method: 'PUT',
    body: { last_read_message_id: lastReadMessageId }
  });
}

export async function v2SetChatChannelMuteStatus(
  channelId: number,
  isMuted: boolean,
  signal?: AbortSignal
): Promise<V2ChatChannelMuteData> {
  const receipt = await v2RequestData<
    unknown,
    { is_muted: boolean }
  >(`/api/v2/chat/channels/${channelId}/mute-status`, {
    method: 'PUT',
    body: { is_muted: isMuted },
    signal
  });
  return { channel_id: channelId, is_muted: confirmedChannelMute(channelId, receipt) };
}

interface DirectConversationListQuery extends V2ChatPageQuery {
  conversation_id?: number;
}

function requireChatPage<T>(response: V2ApiResponse<T[]>, query: V2ChatPageQuery, error: Error): void {
  const meta = response?.meta;
  if (response?.code !== 200 || !Array.isArray(response.data) ||
      meta?.page !== (query.page ?? 1) || meta?.page_size !== (query.page_size ?? 20) ||
      !Number.isSafeInteger(meta?.total) || (meta?.total ?? -1) < 0 ||
      typeof meta?.has_next !== 'boolean' || response.data.length > (meta.page_size ?? 0)) {
    throw error;
  }
}

export async function v2ListDirectConversations(
  query: DirectConversationListQuery = {}
): Promise<V2PagedResult<V2DirectConversation>> {
  const response = await v2Request<
    V2DirectConversation[],
    undefined,
    DirectConversationListQuery
  >('/api/v2/chat/direct-conversations', {
    method: 'GET',
    query
  });
  const invalid = new Error('Invalid direct conversation list response');
  requireChatPage(response, query, invalid);
  const ids = new Set<number>();
  for (const conversation of response.data) {
    if (!conversation || !Number.isSafeInteger(conversation.conversation_id) || conversation.conversation_id <= 0 ||
        ids.has(conversation.conversation_id) ||
        (query.conversation_id !== undefined && conversation.conversation_id !== query.conversation_id) ||
        !conversation.participant || !Number.isSafeInteger(conversation.participant.user_id) || conversation.participant.user_id <= 0 ||
        !Number.isSafeInteger(conversation.unread_count) || conversation.unread_count < 0) {
      throw invalid;
    }
    ids.add(conversation.conversation_id);
  }
  return toV2PagedResult(response);
}

export async function v2CreateDirectConversation(
  payload: V2CreateDirectConversationPayload
): Promise<V2DirectConversation> {
  const conversation = await v2RequestData<
    V2DirectConversation,
    V2CreateDirectConversationPayload
  >('/api/v2/chat/direct-conversations', {
    method: 'POST',
    body: payload
  });
  if (!conversation || !Number.isSafeInteger(conversation.conversation_id) ||
      conversation.conversation_id <= 0 ||
      conversation.participant?.user_id !== payload.target_user_id) {
    throw new Error('Invalid direct conversation response');
  }
  return conversation;
}

export function isDirectMessageForConversation(
  conversationId: number | undefined,
  message: V2DirectMessage | undefined
): message is V2DirectMessage {
  return !!message && Number.isSafeInteger(conversationId) && message.conversation_id === conversationId &&
    message.conversation_id > 0 && Number.isSafeInteger(message.message_id) && message.message_id > 0 &&
    !!message.author && Number.isSafeInteger(message.author.user_id) && message.author.user_id > 0 &&
    typeof message.content === 'string' && typeof message.created_at === 'string' && message.is_deleted === false;
}

export async function v2ListDirectMessages(
  conversationId: number,
  query: V2ChatPageQuery = {}
): Promise<V2PagedResult<V2DirectMessage>> {
  const response = await v2Request<
    V2DirectMessage[],
    undefined,
    V2ChatPageQuery
  >(
    `/api/v2/chat/direct-conversations/${conversationId}/messages`,
    {
      method: 'GET',
      query
    }
  );
  const invalid = new Error('Invalid direct message history response');
  requireChatPage(response, query, invalid);
  const ids = new Set<number>();
  for (const message of response.data) {
    if (!isDirectMessageForConversation(conversationId, message) || ids.has(message.message_id)) {
      throw invalid;
    }
    ids.add(message.message_id);
  }
  return toV2PagedResult(response);
}

export async function v2CreateDirectMessage(
  conversationId: number,
  payload: V2CreateDirectMessagePayload
): Promise<V2DirectMessage> {
  const message = await v2RequestData<
    V2DirectMessage,
    V2CreateDirectMessagePayload
  >(
    `/api/v2/chat/direct-conversations/${conversationId}/messages`,
    {
      method: 'POST',
      body: payload
    }
  );
  if (!message || !Number.isSafeInteger(message.message_id) || message.message_id <= 0 ||
      message.conversation_id !== conversationId || message.is_deleted !== false ||
      message.content !== payload.content.trim()) {
    throw new Error('Invalid direct message response');
  }
  return message;
}

export async function v2DeleteDirectMessage(conversationId: number, messageId: number): Promise<void> {
  const data = await v2RequestData<null>(
    `/api/v2/chat/direct-conversations/${conversationId}/messages/${messageId}`,
    {method: 'DELETE'}
  );
  if (data !== null) throw new Error('Invalid direct message delete receipt');
}
