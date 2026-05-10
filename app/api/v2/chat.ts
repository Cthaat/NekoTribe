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
  return await v2RequestData<V2ChatChannel[]>(
    `/api/v2/chat/groups/${groupId}/channels`,
    { method: 'GET' }
  );
}

export async function v2CreateChatChannel(
  groupId: number,
  payload: V2CreateChatChannelPayload
): Promise<V2ChatChannel> {
  return await v2RequestData<
    V2ChatChannel,
    V2CreateChatChannelPayload
  >(`/api/v2/chat/groups/${groupId}/channels`, {
    method: 'POST',
    body: payload
  });
}

export async function v2UpdateChatChannel(
  channelId: number,
  payload: V2UpdateChatChannelPayload
): Promise<V2ChatChannel> {
  return await v2RequestData<
    V2ChatChannel,
    V2UpdateChatChannelPayload
  >(`/api/v2/chat/channels/${channelId}`, {
    method: 'PATCH',
    body: payload
  });
}

export async function v2DeleteChatChannel(
  channelId: number
): Promise<void> {
  await v2RequestData<null>(
    `/api/v2/chat/channels/${channelId}`,
    { method: 'DELETE' }
  );
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
  await v2RequestData<null>(
    `/api/v2/chat/messages/${messageId}`,
    { method: 'DELETE' }
  );
}

export async function v2UpdateChatMessage(
  messageId: number,
  payload: V2UpdateChatMessagePayload
): Promise<V2ChatMessage> {
  return await v2RequestData<
    V2ChatMessage,
    V2UpdateChatMessagePayload
  >(`/api/v2/chat/messages/${messageId}`, {
    method: 'PATCH',
    body: payload
  });
}

export async function v2SetChatMessagePinStatus(
  messageId: number,
  payload: V2ChatMessagePinPayload
): Promise<V2ChatMessage> {
  return await v2RequestData<
    V2ChatMessage,
    V2ChatMessagePinPayload
  >(`/api/v2/chat/messages/${messageId}/pin-status`, {
    method: 'PUT',
    body: payload
  });
}

export async function v2CreateChatReaction(
  messageId: number,
  payload: V2ChatReactionPayload
): Promise<V2ChatMessage> {
  return await v2RequestData<
    V2ChatMessage,
    V2ChatReactionPayload
  >(`/api/v2/chat/messages/${messageId}/reactions`, {
    method: 'POST',
    body: payload
  });
}

export async function v2DeleteChatReaction(
  messageId: number,
  payload: V2ChatReactionPayload
): Promise<V2ChatMessage> {
  return await v2RequestData<
    V2ChatMessage,
    V2ChatReactionPayload
  >(`/api/v2/chat/messages/${messageId}/reactions`, {
    method: 'DELETE',
    body: payload
  });
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
  isMuted: boolean
): Promise<V2ChatChannelMuteData> {
  return await v2RequestData<
    V2ChatChannelMuteData,
    { is_muted: boolean }
  >(`/api/v2/chat/channels/${channelId}/mute-status`, {
    method: 'PUT',
    body: { is_muted: isMuted }
  });
}

export async function v2ListDirectConversations(
  query: V2ChatPageQuery = {}
): Promise<V2PagedResult<V2DirectConversation>> {
  const response = await v2Request<
    V2DirectConversation[],
    undefined,
    V2ChatPageQuery
  >('/api/v2/chat/direct-conversations', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2CreateDirectConversation(
  payload: V2CreateDirectConversationPayload
): Promise<V2DirectConversation> {
  return await v2RequestData<
    V2DirectConversation,
    V2CreateDirectConversationPayload
  >('/api/v2/chat/direct-conversations', {
    method: 'POST',
    body: payload
  });
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
  return toV2PagedResult(response);
}

export async function v2CreateDirectMessage(
  conversationId: number,
  payload: V2CreateDirectMessagePayload
): Promise<V2DirectMessage> {
  return await v2RequestData<
    V2DirectMessage,
    V2CreateDirectMessagePayload
  >(
    `/api/v2/chat/direct-conversations/${conversationId}/messages`,
    {
      method: 'POST',
      body: payload
    }
  );
}
