import type {
  Channel,
  ChannelCategory
} from '@/components/ChatChannelList.vue';
import type { ChatMessageType } from '@/components/ChatMessage.vue';
import type { ChatMember } from '@/components/ChatMemberList.vue';
import { normalizePublicMediaUrl, normalizeAvatarUrl } from '@/utils/assets';
import { isPrivateMediaContent } from '@/utils/private-media';
import type {
  V2ChatChannel,
  V2ChatGroup,
  V2ChatMember,
  V2ChatMessage,
  V2DirectConversation,
  V2DirectMessage,
  V2MediaAsset
} from '@/types/v2';

export function mergeDirectMessages(
  history: readonly V2DirectMessage[], changes: Iterable<V2DirectMessage>
): V2DirectMessage[] {
  const byId = new Map(history.map(message => [message.message_id, message]));
  for (const message of changes) byId.set(message.message_id, message);
  return [...byId.values()].sort((left, right) =>
    Date.parse(left.created_at) - Date.parse(right.created_at) || left.message_id - right.message_id);
}

export function reconcileDirectHistory(
  page: readonly V2DirectMessage[], retained: readonly V2DirectMessage[],
  live: ReadonlyMap<number, V2DirectMessage | null>
): V2DirectMessage[] {
  const changes = [...live.values()].filter((message): message is V2DirectMessage => message !== null);
  return mergeDirectMessages(page, [...retained, ...changes])
    .filter(message => live.get(message.message_id) !== null)
    .map(message => message.reply_to && live.get(message.reply_to.message_id) === null ? {...message,reply_to:undefined} : message);
}

export interface ChatGroupVM {
  id: number;
  name: string;
  avatar: string;
  canManage: boolean;
  unreadCount: number;
  channelCount: number;
}

export function mapV2ChatGroup(
  group: V2ChatGroup
): ChatGroupVM {
  return {
    id: group.group_id,
    name: group.name,
    avatar: normalizeAvatarUrl(group.avatar_url),
    canManage: group.membership.can_manage,
    unreadCount: group.unread_count,
    channelCount: group.channel_count
  };
}

export function mapV2ChatChannel(
  channel: V2ChatChannel
): Channel {
  return {
    id: channel.channel_id,
    name: channel.name,
    type: channel.type,
    isPrivate: channel.is_private,
    unreadCount: channel.unread_count,
    isMuted: channel.is_muted_by_me,
    lastMessage: channel.last_message?.content || undefined,
    lastMessageTime:
      channel.last_message?.created_at || undefined
  };
}

export function buildChatChannelCategories(
  channels: V2ChatChannel[]
): ChannelCategory[] {
  const grouped = new Map<string, Channel[]>();
  for (const channel of channels) {
    const key = channel.category || '文字频道';
    const existing = grouped.get(key) ?? [];
    existing.push(mapV2ChatChannel(channel));
    grouped.set(key, existing);
  }

  return Array.from(grouped.entries()).map(
    ([name, items], index) => ({
      id: index + 1,
      name,
      channels: items
    })
  );
}

export function mapV2ChatMember(
  member: V2ChatMember
): ChatMember {
  return {
    id: member.user_id,
    username: member.username,
    nickname: member.display_name || member.username,
    avatar: normalizeAvatarUrl(member.avatar_url),
    role: member.role,
    status: member.online_status === 'online' ? 'online' : 'offline',
    lastSeenAt: member.last_seen_at
  };
}

export function mapV2DirectConversationMember(
  conversation: V2DirectConversation
): ChatMember {
  const participant = conversation.participant;
  return {
    id: participant.user_id,
    username: participant.username,
    nickname: participant.display_name || participant.username,
    avatar: normalizeAvatarUrl(participant.avatar_url),
    role: 'member',
    status:
      participant.online_status === 'online' ? 'online' : 'offline',
    lastSeenAt: participant.last_seen_at
  };
}

function mapChatAttachment(media: V2MediaAsset): NonNullable<
  ChatMessageType['attachments']
>[number] {
  const isImage =
    media.media_type === 'image' ||
    media.media_type === 'gif';
  return {
    id: media.media_id,
    name: media.file_name,
    url: isPrivateMediaContent(media.media_id, media.public_url)
      ? media.public_url
      : normalizePublicMediaUrl(media.public_url),
    type: isImage ? 'image' : 'file',
    size: media.file_size
  };
}

export function mapV2ChatMessage(
  message: V2ChatMessage,
  membersById = new Map<number, ChatMember>()
): ChatMessageType {
  const member = membersById.get(message.author.user_id);
  return {
    id: message.message_id,
    channelId: message.channel_id,
    content: message.content,
    type: message.message_type,
    author: {
      id: message.author.user_id,
      username: message.author.username,
      nickname:
        message.author.display_name ||
        message.author.username,
      avatar: normalizeAvatarUrl(message.author.avatar_url),
      role: member?.role,
      isOnline: member?.status !== 'offline'
    },
    createdAt: message.created_at,
    editedAt: message.edited_at ?? undefined,
    isPinned: message.is_pinned,
    canDelete: message.can_delete,
    canPin: message.can_pin,
    replyTo: message.reply_to
      ? {
          id: message.reply_to.message_id,
          content: message.reply_to.content,
          author: {
            nickname: message.reply_to.author_name
          }
        }
      : undefined,
    reactions: message.reactions.map(reaction => ({
      emoji: reaction.emoji,
      count: reaction.count,
      reacted: reaction.reacted_by_me
    })),
    attachments: message.media.map(mapChatAttachment)
  };
}

export function mapV2DirectMessage(message: V2DirectMessage): ChatMessageType {
  return mapV2ChatMessage({
    ...message,channel_id:message.conversation_id,group_id:0,message_type:'text',
    reply_to:message.reply_to ?? null,media:message.media ?? [],reactions:message.reactions ?? [],
    is_pinned:false,can_pin:false,
  });
}

export function replaceChatMessage(
  messages: ChatMessageType[],
  next: ChatMessageType
): ChatMessageType[] {
  const index = messages.findIndex(
    message => message.id === next.id
  );
  if (index === -1) {
    return [...messages, next].sort(
      (a, b) =>
        new Date(a.createdAt).getTime() -
        new Date(b.createdAt).getTime()
    );
  }
  const updated = [...messages];
  updated[index] = next;
  return updated;
}
