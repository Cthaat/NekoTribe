import type {
  Channel,
  ChannelCategory
} from '@/components/ChatChannelList.vue';
import type { ChatMessageType } from '@/components/ChatMessage.vue';
import type { ChatMember } from '@/components/ChatMemberList.vue';
import { normalizeAssetUrl, normalizeAvatarUrl } from '@/utils/assets';
import type {
  V2ChatChannel,
  V2ChatGroup,
  V2ChatMember,
  V2ChatMessage,
  V2MediaAsset
} from '@/types/v2';

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

function mapChatAttachment(media: V2MediaAsset): NonNullable<
  ChatMessageType['attachments']
>[number] {
  const isImage =
    media.media_type === 'image' ||
    media.media_type === 'gif';
  return {
    id: media.media_id,
    name: media.file_name,
    url: normalizeAssetUrl(media.public_url),
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
