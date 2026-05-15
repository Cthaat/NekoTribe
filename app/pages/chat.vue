<script setup lang="ts">
import {
  computed,
  onBeforeUnmount,
  onMounted,
  ref
} from 'vue';
import { toast } from 'vue-sonner';
import {
  Bell,
  BellOff,
  Copy,
  ArrowLeft,
  Link,
  Search,
  UserPlus
} from 'lucide-vue-next';
import ChatChannelList from '@/components/ChatChannelList.vue';
import ChatRoom from '@/components/ChatRoom.vue';
import GroupManageModal from '@/components/GroupManageModal.vue';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Switch } from '@/components/ui/switch';
import { Textarea } from '@/components/ui/textarea';
import AppSendButton from '@/components/app/AppSendButton.vue';
import type {
  Channel,
  ChannelCategory
} from '@/components/ChatChannelList.vue';
import type { ChatMessageType } from '@/components/ChatMessage.vue';
import type { ChatMember } from '@/components/ChatMemberList.vue';
import {
  v2CreateChatChannel,
  v2CreateChatMessage,
  v2CreateDirectConversation,
  v2CreateDirectMessage,
  v2CreateChatReaction,
  v2CreateGroupInvite,
  v2DeleteChatChannel,
  v2DeleteChatMessage,
  v2DeleteChatReaction,
  v2ListChatChannels,
  v2ListChatGroups,
  v2ListChatMembers,
  v2ListChatMessages,
  v2ListDirectMessages,
  v2SetChatChannelMuteStatus,
  v2SetChatMessagePinStatus,
  v2UpdateChatChannel,
  v2UpdateChatMessage,
  v2UploadMedia
} from '@/api/v2';
import { getGroup } from '@/services/groups';
import {
  buildChatChannelCategories,
  mapV2ChatGroup,
  mapV2ChatMember,
  mapV2ChatMessage,
  replaceChatMessage,
  type ChatGroupVM
} from '@/services/chat';
import { v2SearchUsers } from '@/services/users';
import { usePreferenceStore } from '@/stores/user';
import type { Group } from '@/types/groups';
import type {
  V2CreateGroupInviteData,
  V2ChatMessage,
  V2DirectMessage
} from '@/types/v2';
import type { PublicUserVM } from '@/types/users';

const { t } = useAppLocale();
const localePath = useLocalePath();

definePageMeta({
  layout: 'chat'
});

interface ChatWsEvent {
  type: string;
  data?: {
    channel_id?: number;
    conversation_id?: number;
    message_id?: number;
    user_id?: number;
    online_status?: 'online' | 'offline' | 'hidden';
    last_seen_at?: string | null;
    message?: V2ChatMessage;
    direct_message?: V2DirectMessage;
  };
}

const preferenceStore = usePreferenceStore();
const groups = ref<ChatGroupVM[]>([]);
const activeGroup = ref<ChatGroupVM | null>(null);
const channelCategories = ref<ChannelCategory[]>([]);
const activeChannel = ref<Channel | null>(null);
const members = ref<ChatMember[]>([]);
const messages = ref<ChatMessageType[]>([]);
const isLoading = ref(true);
const isLoadingMessages = ref(false);
const isSending = ref(false);
const isCreatingChannel = ref(false);
const errorMessage = ref('');
const messagePage = ref(1);
const hasMoreMessages = ref(false);
const searchQuery = ref('');
const createChannelDialogOpen = ref(false);
const createChannelCategoryId = ref<number | null>(null);
const createChannelName = ref('');
const inviteDialogOpen = ref(false);
const inviteSearchQuery = ref('');
const inviteMessage = ref('');
const inviteMaxUses = ref(25);
const inviteExpireHours = ref(168);
const inviteUsers = ref<PublicUserVM[]>([]);
const selectedInvitee = ref<PublicUserVM | null>(null);
const createdInvite = ref<V2CreateGroupInviteData | null>(null);
const isSearchingInviteUsers = ref(false);
const isCreatingInvite = ref(false);
const notificationSettingsOpen = ref(false);
const groupSettingsOpen = ref(false);
const groupSettingsModel = ref<Group | null>(null);
const directConversationId = ref<number | null>(null);
const directMessageTargetId = ref<number | null>(null);
const directMessageStandaloneTarget = ref<ChatMember | null>(null);
const directMessageContent = ref('');
const directMessages = ref<V2DirectMessage[]>([]);
const isLoadingDirectMessages = ref(false);
const isSendingDirectMessage = ref(false);

const currentUserId = computed(
  () => preferenceStore.preferences.user.id
);
const currentUserName = computed(
  () =>
    preferenceStore.preferences.user.name ||
    preferenceStore.preferences.user.username ||
    t('chat.currentUser.name')
);
const canManage = computed(
  () => activeGroup.value?.canManage ?? false
);
const isDirectMessageStandalone = computed(
  () => directMessageStandaloneTarget.value !== null
);
const chatChannels = computed(() => allChannels());
const existingMemberIds = computed(
  () => new Set(members.value.map(member => member.id))
);
const inviteCandidates = computed(() =>
  inviteUsers.value.filter(
    user =>
      user.id !== currentUserId.value &&
      !existingMemberIds.value.has(user.id)
  )
);
const pinnedMessages = computed(() =>
  messages.value.filter(message => message.isPinned)
);
const membersById = computed(
  () => new Map(members.value.map(member => [member.id, member]))
);
const createChannelCategoryName = computed(() =>
  createChannelCategoryId.value === null
    ? '文字频道'
    : findCategoryName(createChannelCategoryId.value)
);
const canSubmitCreateChannel = computed(
  () =>
    createChannelName.value.trim().length > 0 &&
    !isCreatingChannel.value
);

let ws: WebSocket | null = null;
let shouldReconnectWs = true;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let wsHeartbeatTimer: ReturnType<typeof setInterval> | null = null;
let searchTimer: ReturnType<typeof setTimeout> | null = null;
let inviteSearchTimer: ReturnType<typeof setTimeout> | null =
  null;

function allChannels(): Channel[] {
  return channelCategories.value.flatMap(
    category => category.channels
  );
}

function findCategoryName(categoryId: number): string {
  return (
    channelCategories.value.find(
      category => category.id === categoryId
    )?.name ?? '文字频道'
  );
}

function absoluteUrl(pathOrUrl: string): string {
  if (
    /^https?:\/\//i.test(pathOrUrl) ||
    typeof window === 'undefined'
  ) {
    return pathOrUrl;
  }
  return new URL(pathOrUrl, window.location.origin).toString();
}

function inviteUrl(
  invite: V2CreateGroupInviteData | null
): string | null {
  if (!invite) return null;
  if (invite.invite_url) {
    return absoluteUrl(invite.invite_url);
  }
  if (invite.invite_code) {
    return absoluteUrl(`/groups/invite/${invite.invite_code}`);
  }
  return null;
}

async function copyText(value: string): Promise<void> {
  if (typeof navigator === 'undefined' || !navigator.clipboard) {
    return;
  }
  await navigator.clipboard.writeText(value);
}

async function copyCreatedInvite(): Promise<void> {
  const url = inviteUrl(createdInvite.value);
  if (!url) return;
  await copyText(url);
  toast.success(t('chat.feedback.inviteCopied'));
}

function openInviteDialog(): void {
  inviteDialogOpen.value = true;
  inviteSearchQuery.value = '';
  inviteMessage.value = '';
  selectedInvitee.value = null;
  createdInvite.value = null;
  inviteUsers.value = [];
}

function openNotificationSettings(): void {
  notificationSettingsOpen.value = true;
}

async function openGroupSettings(): Promise<void> {
  if (!activeGroup.value) return;
  groupSettingsOpen.value = true;
  try {
    groupSettingsModel.value = await getGroup(activeGroup.value.id);
  } catch (error) {
    toast.error(t('chat.feedback.loadSettingsFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
    groupSettingsOpen.value = false;
  }
}

function handleGroupSettingsUpdated(group: Group): void {
  groupSettingsModel.value = group;
  const target = groups.value.find(item => item.id === group.id);
  if (target) {
    target.name = group.name;
    target.avatar = group.avatar;
  }
  if (activeGroup.value?.id === group.id) {
    activeGroup.value = {
      ...activeGroup.value,
      name: group.name,
      avatar: group.avatar
    };
  }
}

function handleGroupDeleted(groupId: number): void {
  groups.value = groups.value.filter(group => group.id !== groupId);
  groupSettingsOpen.value = false;
  groupSettingsModel.value = null;
  if (activeGroup.value?.id !== groupId) return;
  activeGroup.value = null;
  activeChannel.value = null;
  channelCategories.value = [];
  messages.value = [];
  const next = groups.value[0];
  if (next) {
    void loadGroup(next);
  }
}

function sendWs(payload: Record<string, unknown>): void {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function stopWsHeartbeat(): void {
  if (wsHeartbeatTimer) {
    clearInterval(wsHeartbeatTimer);
    wsHeartbeatTimer = null;
  }
}

function startWsHeartbeat(): void {
  stopWsHeartbeat();
  sendWs({ type: 'ping' });
  wsHeartbeatTimer = setInterval(() => {
    sendWs({ type: 'ping' });
  }, 30000);
}

function joinWsChannel(channelId: number): void {
  sendWs({
    type: 'chat_join_channel',
    data: { channelId }
  });
}

function leaveWsChannel(channelId: number): void {
  sendWs({
    type: 'chat_leave_channel',
    data: { channelId }
  });
}

function upsertMessage(message: ChatMessageType): void {
  messages.value = replaceChatMessage(messages.value, message);
}

function upsertDirectMessage(message: V2DirectMessage): void {
  const index = directMessages.value.findIndex(
    item => item.message_id === message.message_id
  );
  if (index === -1) {
    directMessages.value = [...directMessages.value, message].sort(
      (a, b) =>
        new Date(a.created_at).getTime() -
        new Date(b.created_at).getTime()
    );
    return;
  }

  const updated = [...directMessages.value];
  updated[index] = message;
  directMessages.value = updated;
}

function updateChannelPreview(
  rawMessage: V2ChatMessage,
  isActiveChannel: boolean
): void {
  for (const category of channelCategories.value) {
    const channel = category.channels.find(
      item => item.id === rawMessage.channel_id
    );
    if (!channel) continue;

    channel.lastMessage =
      rawMessage.content ||
      (rawMessage.media.length > 0
        ? t('chat.message.attachmentPreview')
        : '');
    channel.lastMessageTime = rawMessage.created_at;
    if (!isActiveChannel && !channel.isMuted) {
      channel.unreadCount = (channel.unreadCount ?? 0) + 1;
    }
    break;
  }
}

function updateMemberPresence(
  userId: number,
  onlineStatus: 'online' | 'offline' | 'hidden',
  lastSeenAt?: string | null
): void {
  members.value = members.value.map(member =>
    member.id === userId
      ? {
          ...member,
          status:
            onlineStatus === 'online' ? 'online' : 'offline',
          lastSeenAt: lastSeenAt ?? member.lastSeenAt
        }
      : member
  );
  if (directMessageStandaloneTarget.value?.id === userId) {
    directMessageStandaloneTarget.value = {
      ...directMessageStandaloneTarget.value,
      status: onlineStatus === 'online' ? 'online' : 'offline',
      lastSeenAt:
        lastSeenAt ?? directMessageStandaloneTarget.value.lastSeenAt
    };
  }
}

function handleWsMessage(event: MessageEvent<string>): void {
  let payload: ChatWsEvent;
  try {
    payload = JSON.parse(event.data) as ChatWsEvent;
  } catch {
    return;
  }

  const channelId = payload.data?.channel_id;
  if (
    payload.type === 'presence_update' &&
    payload.data?.user_id &&
    payload.data.online_status
  ) {
    updateMemberPresence(
      payload.data.user_id,
      payload.data.online_status,
      payload.data.last_seen_at
    );
    return;
  }

  const isActiveChannel =
    channelId !== undefined &&
    activeChannel.value?.id === channelId;

  if (
    [
      'chat_message',
      'chat_message_updated',
      'chat_reaction_updated'
    ].includes(payload.type) &&
    payload.data?.message
  ) {
    const vm = mapV2ChatMessage(
      payload.data.message,
      membersById.value
    );
    if (isActiveChannel) {
      upsertMessage(vm);
    }
    if (payload.type === 'chat_message') {
      updateChannelPreview(payload.data.message, isActiveChannel);
    }
    return;
  }

  if (
    payload.type === 'direct_message' &&
    payload.data?.direct_message &&
    payload.data.conversation_id === directConversationId.value
  ) {
    upsertDirectMessage(payload.data.direct_message);
    return;
  }

  if (
    payload.type === 'chat_message_deleted' &&
    payload.data?.message_id
  ) {
    messages.value = messages.value.filter(
      message => message.id !== payload.data?.message_id
    );
  }
}

function connectWs(): void {
  if (!import.meta.client || ws) return;

  const protocol =
    window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${protocol}//${window.location.host}/_ws`);
  ws.onopen = () => {
    startWsHeartbeat();
    if (activeChannel.value) {
      joinWsChannel(activeChannel.value.id);
    }
  };
  ws.onmessage = handleWsMessage;
  ws.onclose = () => {
    ws = null;
    stopWsHeartbeat();
    if (!shouldReconnectWs) return;
    reconnectTimer = setTimeout(connectWs, 3000);
  };
}

async function loadMessages(
  channelId: number,
  reset = true,
  q = searchQuery.value
): Promise<void> {
  if (isLoadingMessages.value) return;
  isLoadingMessages.value = true;
  try {
    const page = reset ? 1 : messagePage.value + 1;
    const result = await v2ListChatMessages(channelId, {
      page,
      page_size: 50,
      q: q.trim() || undefined
    });
    const mapped = result.items.map(message =>
      mapV2ChatMessage(message, membersById.value)
    );
    messages.value = reset
      ? mapped
      : [...mapped, ...messages.value];
    messagePage.value = page;
    hasMoreMessages.value = result.meta?.has_next ?? false;
  } catch {
    toast.error(t('chat.feedback.loadMessagesFailed'));
  } finally {
    isLoadingMessages.value = false;
  }
}

async function refreshChannels(
  preferredChannelId?: number
): Promise<void> {
  if (!activeGroup.value) return;
  const channels = await v2ListChatChannels(activeGroup.value.id);
  channelCategories.value = buildChatChannelCategories(channels);

  const availableChannels = allChannels().filter(
    channel =>
      channel.type === 'text' ||
      channel.type === 'announcement'
  );
  const nextChannel =
    availableChannels.find(
      channel => channel.id === preferredChannelId
    ) ??
    availableChannels.find(
      channel => channel.id === activeChannel.value?.id
    ) ??
    availableChannels[0] ??
    null;

  activeChannel.value = nextChannel;
}

async function loadGroup(group: ChatGroupVM): Promise<Channel | null> {
  activeGroup.value = group;
  const [memberItems] = await Promise.all([
    v2ListChatMembers(group.id),
    refreshChannels()
  ]);
  members.value = memberItems.map(mapV2ChatMember);

  if (activeChannel.value) {
    await loadMessages(activeChannel.value.id);
  }
  return activeChannel.value;
}

async function loadChat(): Promise<void> {
  isLoading.value = true;
  errorMessage.value = '';
  try {
    const result = await v2ListChatGroups({
      page: 1,
      page_size: 50
    });
    groups.value = result.items.map(mapV2ChatGroup);
    const firstGroup = groups.value[0] ?? null;
    if (firstGroup) {
      await loadGroup(firstGroup);
      connectWs();
    }
  } catch {
    errorMessage.value = t('chat.feedback.loadFailed');
  } finally {
    isLoading.value = false;
  }
}

async function handleSelectChannel(
  channel: Channel
): Promise<void> {
  if (activeChannel.value?.id === channel.id) return;
  if (activeChannel.value) {
    leaveWsChannel(activeChannel.value.id);
  }
  activeChannel.value = channel;
  channel.unreadCount = 0;
  searchQuery.value = '';
  await loadMessages(channel.id);
  joinWsChannel(channel.id);
}

async function handleSelectGroup(groupId: number): Promise<void> {
  const group = groups.value.find(item => item.id === groupId);
  if (!group || group.id === activeGroup.value?.id) return;

  if (activeChannel.value) {
    leaveWsChannel(activeChannel.value.id);
  }
  activeChannel.value = null;
  messages.value = [];
  searchQuery.value = '';
  const nextChannel = await loadGroup(group);
  if (nextChannel) {
    joinWsChannel(nextChannel.id);
  }
}

async function uploadAttachments(
  files: File[] = []
): Promise<number[]> {
  const mediaIds: number[] = [];
  for (const file of files) {
    const formData = new FormData();
    formData.append('file', file);
    formData.append('alt_text', file.name);
    const media = await v2UploadMedia(formData);
    mediaIds.push(media.media_id);
  }
  return mediaIds;
}

async function handleSendMessage(
  content: string,
  attachments?: File[],
  replyToMessageId?: number
): Promise<void> {
  if (!activeChannel.value || isSending.value) return;
  isSending.value = true;
  try {
    const mediaIds = await uploadAttachments(attachments);
    const created = await v2CreateChatMessage(
      activeChannel.value.id,
      {
        content,
        media_ids: mediaIds,
        reply_to_message_id: replyToMessageId ?? null
      }
    );
    upsertMessage(
      mapV2ChatMessage(created, membersById.value)
    );
    updateChannelPreview(created, true);
    toast.success(t('chat.feedback.sent'));
  } catch {
    toast.error(t('chat.feedback.sendFailed'));
  } finally {
    isSending.value = false;
  }
}

async function handleReact(
  messageId: number,
  emoji: string
): Promise<void> {
  const message = messages.value.find(item => item.id === messageId);
  const reacted = message?.reactions?.some(
    reaction => reaction.emoji === emoji && reaction.reacted
  );
  try {
    const updated = reacted
      ? await v2DeleteChatReaction(messageId, { emoji })
      : await v2CreateChatReaction(messageId, { emoji });
    upsertMessage(
      mapV2ChatMessage(updated, membersById.value)
    );
  } catch {
    toast.error(t('chat.feedback.reactionFailed'));
  }
}

async function handleDeleteMessage(
  messageId: number
): Promise<void> {
  try {
    await v2DeleteChatMessage(messageId);
    messages.value = messages.value.filter(
      message => message.id !== messageId
    );
    toast.success(t('chat.feedback.deleted'));
  } catch {
    toast.error(t('chat.feedback.deleteFailed'));
  }
}

async function handleEditMessage(
  message: ChatMessageType
): Promise<void> {
  if (!import.meta.client) return;
  const content = window
    .prompt(t('chat.prompts.messageContent'), message.content)
    ?.trim();
  if (!content || content === message.content) return;

  try {
    const updated = await v2UpdateChatMessage(message.id, {
      content
    });
    upsertMessage(
      mapV2ChatMessage(updated, membersById.value)
    );
    toast.success(t('chat.feedback.messageUpdated'));
  } catch {
    toast.error(t('chat.feedback.updateMessageFailed'));
  }
}

async function handlePinMessage(messageId: number): Promise<void> {
  const current = messages.value.find(
    message => message.id === messageId
  );
  if (!current) return;

  try {
    const updated = await v2SetChatMessagePinStatus(messageId, {
      is_pinned: !current.isPinned
    });
    upsertMessage(
      mapV2ChatMessage(updated, membersById.value)
    );
    toast.success(
      updated.is_pinned
        ? t('chat.feedback.pinned')
        : t('chat.feedback.unpinned')
    );
  } catch {
    toast.error(t('chat.feedback.pinFailed'));
  }
}

function handleCreateChannel(categoryId: number): void {
  if (!activeGroup.value) return;
  createChannelCategoryId.value = categoryId;
  createChannelName.value = '';
  createChannelDialogOpen.value = true;
}

async function submitCreateChannel(): Promise<void> {
  const group = activeGroup.value;
  const categoryId = createChannelCategoryId.value;
  const name = createChannelName.value.trim();
  if (!group || categoryId === null || !name) return;

  isCreatingChannel.value = true;
  try {
    const created = await v2CreateChatChannel(group.id, {
      name,
      type: 'text',
      category: findCategoryName(categoryId)
    });
    await refreshChannels(created.channel_id);
    if (activeChannel.value) {
      await loadMessages(activeChannel.value.id);
      joinWsChannel(activeChannel.value.id);
    }
    createChannelDialogOpen.value = false;
    toast.success(t('chat.feedback.channelCreated'));
  } catch {
    toast.error(t('chat.feedback.createChannelFailed'));
  } finally {
    isCreatingChannel.value = false;
  }
}

async function handleEditChannel(
  channel: Channel
): Promise<void> {
  if (!import.meta.client) return;
  const name = window
    .prompt(t('chat.prompts.channelName'), channel.name)
    ?.trim();
  if (!name || name === channel.name) return;

  try {
    const updated = await v2UpdateChatChannel(channel.id, {
      name
    });
    await refreshChannels(updated.channel_id);
    toast.success(t('chat.feedback.channelUpdated'));
  } catch {
    toast.error(t('chat.feedback.updateChannelFailed'));
  }
}

async function handleDeleteChannel(
  channelId: number
): Promise<void> {
  if (!import.meta.client) return;
  if (!window.confirm(t('chat.prompts.deleteChannel'))) return;

  try {
    await v2DeleteChatChannel(channelId);
    if (activeChannel.value?.id === channelId) {
      leaveWsChannel(channelId);
      messages.value = [];
      activeChannel.value = null;
    }
    await refreshChannels();
    if (activeChannel.value) {
      await loadMessages(activeChannel.value.id);
      joinWsChannel(activeChannel.value.id);
    }
    toast.success(t('chat.feedback.channelDeleted'));
  } catch {
    toast.error(t('chat.feedback.deleteChannelFailed'));
  }
}

async function handleToggleChannelMute(
  channelId?: number
): Promise<void> {
  const targetId = channelId ?? activeChannel.value?.id;
  if (!targetId) return;
  const channel = allChannels().find(item => item.id === targetId);
  if (!channel) return;

  try {
    const nextMuted = !channel.isMuted;
    await v2SetChatChannelMuteStatus(targetId, nextMuted);
    channel.isMuted = nextMuted;
    if (activeChannel.value?.id === targetId) {
      activeChannel.value.isMuted = nextMuted;
    }
    toast.success(
      nextMuted
        ? t('chat.feedback.channelMuted')
        : t('chat.feedback.channelUnmuted')
    );
  } catch {
    toast.error(t('chat.feedback.muteFailed'));
  }
}

function handleSearch(query: string): void {
  searchQuery.value = query;
  if (!activeChannel.value) return;
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    if (activeChannel.value) {
      void loadMessages(activeChannel.value.id, true, query);
    }
  }, 300);
}

function handleInviteSearchInput(): void {
  if (inviteSearchTimer) clearTimeout(inviteSearchTimer);
  inviteSearchTimer = setTimeout(() => {
    void searchInviteUsers();
  }, 300);
}

async function searchInviteUsers(): Promise<void> {
  const q = inviteSearchQuery.value.trim();
  selectedInvitee.value = null;
  createdInvite.value = null;

  if (q.length < 2) {
    inviteUsers.value = [];
    return;
  }

  isSearchingInviteUsers.value = true;
  try {
    const result = await v2SearchUsers({
      q,
      page: 1,
      pageSize: 12,
      sort: 'popular'
    });
    inviteUsers.value = result.items;
  } catch (error) {
    toast.error(t('chat.feedback.searchUsersFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    isSearchingInviteUsers.value = false;
  }
}

function selectInvitee(user: PublicUserVM): void {
  selectedInvitee.value = user;
  createdInvite.value = null;
}

function normalizedPositiveInteger(
  value: number,
  fallback: number
): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(Math.trunc(value), 1);
}

async function submitInvite(): Promise<void> {
  const group = activeGroup.value;
  if (!group || isCreatingInvite.value) return;

  isCreatingInvite.value = true;
  try {
    inviteMaxUses.value = normalizedPositiveInteger(
      inviteMaxUses.value,
      25
    );
    inviteExpireHours.value = normalizedPositiveInteger(
      inviteExpireHours.value,
      168
    );
    const invite = await v2CreateGroupInvite(group.id, {
      invitee_id: selectedInvitee.value?.id ?? null,
      max_uses: selectedInvitee.value ? 1 : inviteMaxUses.value,
      expire_hours: inviteExpireHours.value,
      message: inviteMessage.value.trim() || undefined
    });
    createdInvite.value = invite;

    const url = inviteUrl(invite);
    if (url) {
      await copyText(url);
    }
    toast.success(
      selectedInvitee.value
        ? t('chat.feedback.memberInvited')
        : t('chat.feedback.inviteCreated')
    );
  } catch (error) {
    toast.error(t('chat.feedback.inviteFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    isCreatingInvite.value = false;
  }
}

function handleLoadMore(): void {
  if (!activeChannel.value || !hasMoreMessages.value) return;
  void loadMessages(activeChannel.value.id, false);
}

function openMemberProfile(userId: number): void {
  if (!Number.isFinite(userId) || userId <= 0) return;
  void navigateTo(localePath(`/user/${userId}/profile`));
}

async function handleOpenDirectMessage(
  member: ChatMember
): Promise<void> {
  directMessageTargetId.value = member.id;
  directConversationId.value = null;
  directMessages.value = [];
  isLoadingDirectMessages.value = true;

  try {
    const conversation = await v2CreateDirectConversation({
      target_user_id: member.id
    });
    directConversationId.value = conversation.conversation_id;
    const result = await v2ListDirectMessages(
      conversation.conversation_id,
      {
        page: 1,
        page_size: 50
      }
    );
    directMessages.value = result.items;
  } catch {
    toast.error(t('chat.feedback.loadDirectMessagesFailed'));
  } finally {
    isLoadingDirectMessages.value = false;
  }
}

async function handleOpenDirectMessageStandalone(
  member: ChatMember
): Promise<void> {
  await handleOpenDirectMessage(member);
  directMessageContent.value = '';
  directMessageStandaloneTarget.value = member;
}

function closeDirectMessageStandalone(): void {
  directMessageStandaloneTarget.value = null;
}

function handleSendDirectMessageKeydown(
  event: KeyboardEvent
): void {
  if (event.key !== 'Enter' || event.shiftKey) return;
  event.preventDefault();
  void submitStandaloneDirectMessage();
}

async function submitStandaloneDirectMessage(): Promise<void> {
  const target = directMessageStandaloneTarget.value;
  const content = directMessageContent.value.trim();
  if (!target || !content) return;

  await handleSendDirectMessage(target.id, content);
  directMessageContent.value = '';
}

async function handleSendDirectMessage(
  targetUserId: number,
  content: string
): Promise<void> {
  if (isSendingDirectMessage.value) return;
  isSendingDirectMessage.value = true;

  try {
    let conversationId = directConversationId.value;
    if (
      !conversationId ||
      directMessageTargetId.value !== targetUserId
    ) {
      const conversation = await v2CreateDirectConversation({
        target_user_id: targetUserId
      });
      conversationId = conversation.conversation_id;
      directConversationId.value = conversationId;
      directMessageTargetId.value = targetUserId;
    }

    const created = await v2CreateDirectMessage(conversationId, {
      content
    });
    upsertDirectMessage(created);
    toast.success(t('chat.feedback.directMessageSent'));
  } catch {
    toast.error(t('chat.feedback.directMessageFailed'));
  } finally {
    isSendingDirectMessage.value = false;
  }
}

onMounted(() => {
  void loadChat();
});

onBeforeUnmount(() => {
  shouldReconnectWs = false;
  if (reconnectTimer) clearTimeout(reconnectTimer);
  stopWsHeartbeat();
  if (searchTimer) clearTimeout(searchTimer);
  if (inviteSearchTimer) clearTimeout(inviteSearchTimer);
  if (activeChannel.value) {
    leaveWsChannel(activeChannel.value.id);
  }
  ws?.close();
});
</script>

<template>
  <div class="flex h-full min-h-0 w-full overflow-hidden">
    <div
      v-if="!isDirectMessageStandalone"
      class="hidden h-full min-h-0 w-60 flex-shrink-0 overflow-hidden border-r bg-muted/20 md:block"
    >
      <ChatChannelList
        :categories="channelCategories"
        :active-channel-id="activeChannel?.id"
        :group-name="activeGroup?.name"
        :group-avatar="activeGroup?.avatar"
        :groups="groups"
        :active-group-id="activeGroup?.id"
        :can-manage="canManage"
        :current-user-name="currentUserName"
        @select-group="handleSelectGroup"
        @select="handleSelectChannel"
        @create-channel="handleCreateChannel"
        @edit-channel="handleEditChannel"
        @delete-channel="handleDeleteChannel"
        @toggle-mute="handleToggleChannelMute"
        @invite-members="openInviteDialog"
        @notification-settings="openNotificationSettings"
        @settings="openGroupSettings"
      />
    </div>

    <Dialog v-model:open="createChannelDialogOpen">
      <DialogContent class="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {{ t('chat.dialogs.createChannel.title') }}
          </DialogTitle>
          <DialogDescription>
            {{
              t('chat.dialogs.createChannel.description', {
                category: createChannelCategoryName
              })
            }}
          </DialogDescription>
        </DialogHeader>

        <form
          class="space-y-4"
          @submit.prevent="submitCreateChannel"
        >
          <div class="space-y-2">
            <Label for="create-channel-name">
              {{ t('chat.dialogs.createChannel.nameLabel') }}
            </Label>
            <Input
              id="create-channel-name"
              v-model="createChannelName"
              :placeholder="t('chat.prompts.channelName')"
              :disabled="isCreatingChannel"
              maxlength="64"
              autocomplete="off"
            />
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              :disabled="isCreatingChannel"
              @click="createChannelDialogOpen = false"
            >
              {{ t('common.cancel') }}
            </Button>
            <Button
              type="submit"
              :disabled="!canSubmitCreateChannel"
            >
              {{
                isCreatingChannel
                  ? t('common.processing')
                  : t('common.create')
              }}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>

    <Dialog v-model:open="inviteDialogOpen">
      <DialogContent class="sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle class="flex items-center gap-2">
            <UserPlus class="h-5 w-5" />
            {{ t('chat.invite.title') }}
          </DialogTitle>
          <DialogDescription>
            {{
              t('chat.invite.description', {
                group: activeGroup?.name || t('chat.groupFallbackName')
              })
            }}
          </DialogDescription>
        </DialogHeader>

        <div class="grid gap-5 md:grid-cols-[1.15fr_0.85fr]">
          <div class="space-y-4">
            <div class="space-y-2">
              <Label for="chat-invite-search">
                {{ t('chat.invite.searchLabel') }}
              </Label>
              <div class="relative">
                <Search
                  class="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
                />
                <Input
                  id="chat-invite-search"
                  v-model="inviteSearchQuery"
                  class="pl-9"
                  :placeholder="t('chat.invite.searchPlaceholder')"
                  autocomplete="off"
                  @input="handleInviteSearchInput"
                />
              </div>
              <p class="text-xs text-muted-foreground">
                {{ t('chat.invite.searchHint') }}
              </p>
            </div>

            <div
              v-if="selectedInvitee"
              class="flex items-center justify-between gap-3 rounded-lg border bg-muted/30 p-3"
            >
              <div class="flex min-w-0 items-center gap-3">
                <Avatar class="h-9 w-9">
                  <AvatarImage
                    :src="selectedInvitee.avatarUrl"
                    :alt="selectedInvitee.name"
                  />
                  <AvatarFallback>
                    {{ selectedInvitee.name.slice(0, 2) }}
                  </AvatarFallback>
                </Avatar>
                <div class="min-w-0">
                  <div class="truncate text-sm font-medium">
                    {{ selectedInvitee.name }}
                  </div>
                  <div class="truncate text-xs text-muted-foreground">
                    @{{ selectedInvitee.username }}
                  </div>
                </div>
              </div>
              <Button
                variant="ghost"
                size="sm"
                @click="selectedInvitee = null"
              >
                {{ t('chat.invite.clearSelection') }}
              </Button>
            </div>

            <ScrollArea class="h-64 rounded-lg border">
              <div class="p-2">
                <div
                  v-if="isSearchingInviteUsers"
                  class="p-6 text-center text-sm text-muted-foreground"
                >
                  {{ t('chat.invite.searching') }}
                </div>
                <div
                  v-else-if="
                    inviteSearchQuery.trim().length >= 2 &&
                    inviteCandidates.length === 0
                  "
                  class="p-6 text-center text-sm text-muted-foreground"
                >
                  {{ t('chat.invite.noResults') }}
                </div>
                <div
                  v-else-if="inviteSearchQuery.trim().length < 2"
                  class="p-6 text-center text-sm text-muted-foreground"
                >
                  {{ t('chat.invite.emptySearch') }}
                </div>
                <Button
                  v-for="user in inviteCandidates"
                  :key="user.id"
                  variant="ghost"
                  class="h-auto w-full justify-start gap-3 p-2 text-left"
                  :class="{
                    'bg-muted': selectedInvitee?.id === user.id
                  }"
                  @click="selectInvitee(user)"
                >
                  <Avatar class="h-9 w-9">
                    <AvatarImage
                      :src="user.avatarUrl"
                      :alt="user.name"
                    />
                    <AvatarFallback>
                      {{ user.name.slice(0, 2) }}
                    </AvatarFallback>
                  </Avatar>
                  <div class="min-w-0 flex-1">
                    <div class="truncate text-sm font-medium">
                      {{ user.name }}
                    </div>
                    <div class="truncate text-xs text-muted-foreground">
                      @{{ user.username }}
                    </div>
                  </div>
                  <Badge
                    v-if="selectedInvitee?.id === user.id"
                    variant="secondary"
                  >
                    {{ t('chat.invite.selected') }}
                  </Badge>
                </Button>
              </div>
            </ScrollArea>
          </div>

          <div class="space-y-4">
            <Card class="gap-0 py-0">
              <CardContent class="p-4">
                <div class="flex items-center gap-2 font-medium">
                  <Link class="h-4 w-4" />
                  {{ t('chat.invite.linkTitle') }}
                </div>
                <p class="mt-2 text-sm text-muted-foreground">
                  {{ t('chat.invite.linkDescription') }}
                </p>
              </CardContent>
            </Card>

            <div class="grid grid-cols-2 gap-3">
              <div class="space-y-2">
                <Label for="chat-invite-max-uses">
                  {{ t('chat.invite.maxUses') }}
                </Label>
                <Input
                  id="chat-invite-max-uses"
                  v-model.number="inviteMaxUses"
                  type="number"
                  min="1"
                  :disabled="!!selectedInvitee"
                />
              </div>
              <div class="space-y-2">
                <Label for="chat-invite-expire-hours">
                  {{ t('chat.invite.expireHours') }}
                </Label>
                <Input
                  id="chat-invite-expire-hours"
                  v-model.number="inviteExpireHours"
                  type="number"
                  min="1"
                />
              </div>
            </div>

            <div class="space-y-2">
              <Label for="chat-invite-message">
                {{ t('chat.invite.messageLabel') }}
              </Label>
              <Textarea
                id="chat-invite-message"
                v-model="inviteMessage"
                class="min-h-24 resize-none"
                :placeholder="t('chat.invite.messagePlaceholder')"
                maxlength="200"
              />
            </div>

            <Card
              v-if="createdInvite"
              class="gap-0 bg-muted/30 py-0"
            >
              <CardContent class="p-3">
                <div class="text-sm font-medium">
                  {{ t('chat.invite.createdTitle') }}
                </div>
                <div
                  v-if="inviteUrl(createdInvite)"
                  class="mt-2 flex items-center gap-2"
                >
                  <Input
                    :model-value="inviteUrl(createdInvite) || ''"
                    readonly
                    class="h-8 text-xs"
                  />
                  <Button
                    size="icon"
                    variant="outline"
                    @click="copyCreatedInvite"
                  >
                    <Copy class="h-4 w-4" />
                  </Button>
                </div>
                <p v-else class="mt-2 text-sm text-muted-foreground">
                  {{ t('chat.invite.targetedCreated') }}
                </p>
              </CardContent>
            </Card>
          </div>
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            :disabled="isCreatingInvite"
            @click="inviteDialogOpen = false"
          >
            {{ t('common.cancel') }}
          </Button>
          <Button
            type="button"
            :disabled="isCreatingInvite || !activeGroup"
            @click="submitInvite"
          >
            {{
              isCreatingInvite
                ? t('common.processing')
                : selectedInvitee
                  ? t('chat.invite.sendInvite')
                  : t('chat.invite.createLink')
            }}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <Dialog v-model:open="notificationSettingsOpen">
      <DialogContent class="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle class="flex items-center gap-2">
            <Bell class="h-5 w-5" />
            {{ t('chat.notifications.groupTitle') }}
          </DialogTitle>
          <DialogDescription>
            {{
              t('chat.notifications.groupDescription', {
                group: activeGroup?.name || t('chat.groupFallbackName')
              })
            }}
          </DialogDescription>
        </DialogHeader>

        <ScrollArea class="max-h-[56vh] pr-4">
          <div class="space-y-3">
            <Card
              v-if="chatChannels.length === 0"
              class="gap-0 border-dashed py-0"
            >
              <CardContent
                class="p-8 text-center text-sm text-muted-foreground"
              >
                {{ t('chat.notifications.noChannels') }}
              </CardContent>
            </Card>
            <Card
              v-for="channel in chatChannels"
              :key="channel.id"
              class="gap-0 py-0"
            >
              <CardContent
                class="flex items-center justify-between gap-4 p-3"
              >
                <div class="min-w-0">
                  <div class="flex items-center gap-2">
                    <component
                      :is="channel.isMuted ? BellOff : Bell"
                      class="h-4 w-4 text-muted-foreground"
                    />
                    <span class="truncate text-sm font-medium">
                      # {{ channel.name }}
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-muted-foreground">
                    {{
                      channel.isMuted
                        ? t('chat.notifications.channelMuted')
                        : t('chat.notifications.channelUnmuted')
                    }}
                  </p>
                </div>
                <Switch
                  :model-value="!!channel.isMuted"
                  @update:model-value="
                    () => handleToggleChannelMute(channel.id)
                  "
                />
              </CardContent>
            </Card>
          </div>
        </ScrollArea>
      </DialogContent>
    </Dialog>

    <GroupManageModal
      v-if="groupSettingsModel"
      v-model:open="groupSettingsOpen"
      :group="groupSettingsModel"
      @updated="handleGroupSettingsUpdated"
      @deleted="handleGroupDeleted"
    />

    <div class="h-full min-h-0 flex-1 min-w-0 overflow-hidden">
      <div
        v-if="isLoading"
        class="h-full flex items-center justify-center text-muted-foreground"
      >
        {{ t('common.loading') }}
      </div>
      <div
        v-else-if="errorMessage"
        class="h-full flex flex-col items-center justify-center gap-3 text-muted-foreground"
      >
        <p>{{ errorMessage }}</p>
        <Button
          variant="link"
          class="h-auto p-0"
          @click="loadChat"
        >
          {{ t('common.refresh') }}
        </Button>
      </div>
      <div
        v-else-if="!activeGroup"
        class="h-full flex items-center justify-center text-muted-foreground"
      >
        {{ t('chat.empty.noGroups') }}
      </div>
      <template v-else>
        <div
          v-if="isDirectMessageStandalone && directMessageStandaloneTarget"
          class="flex h-full min-h-0 flex-1 flex-col overflow-hidden"
        >
          <div class="flex items-center gap-3 border-b bg-background px-4 py-3">
            <Button
              variant="ghost"
              size="icon"
              class="h-9 w-9 rounded-full"
              @click="closeDirectMessageStandalone"
            >
              <ArrowLeft class="h-4 w-4" />
              <span class="sr-only">返回频道</span>
            </Button>

            <Avatar class="h-10 w-10 shrink-0 ring-1 ring-border">
              <AvatarImage
                :src="directMessageStandaloneTarget.avatar"
                :alt="directMessageStandaloneTarget.nickname"
              />
              <AvatarFallback>
                {{ directMessageStandaloneTarget.nickname.slice(0, 2) }}
              </AvatarFallback>
            </Avatar>

            <div class="min-w-0 flex-1">
              <div class="truncate text-base font-semibold leading-6">
                {{ directMessageStandaloneTarget.nickname }}
              </div>
              <div class="truncate text-sm text-muted-foreground">
                @{{ directMessageStandaloneTarget.username }}
              </div>
            </div>

            <span class="rounded-full border bg-muted/40 px-3 py-1 text-xs text-muted-foreground">
              {{ t('chat.directMessage.title') }}
            </span>
          </div>

          <div class="relative min-h-0 flex-1">
            <ScrollArea class="h-full">
              <div class="min-h-full px-4 py-4">
                <div
                  v-if="isLoadingDirectMessages"
                  class="flex min-h-[40vh] items-center justify-center text-sm text-muted-foreground"
                >
                  {{ t('chat.directMessage.loading') }}
                </div>

                <div
                  v-else-if="!directMessages?.length"
                  class="flex min-h-[40vh] flex-col items-center justify-center text-center text-muted-foreground"
                >
                  <div class="font-medium text-foreground">
                    {{ t('chat.directMessage.emptyTitle') }}
                  </div>
                  <div class="mt-1 text-sm">
                    {{ t('chat.directMessage.emptyDescription') }}
                  </div>
                </div>

                <div v-else class="flex flex-col gap-3 pb-4">
                  <div
                    v-for="message in directMessages"
                    :key="message.message_id"
                    class="flex"
                    :class="{ 'justify-end': message.author.user_id === currentUserId }"
                  >
                    <div class="max-w-[72%]">
                      <div
                        class="rounded-2xl px-4 py-3 text-sm leading-6 shadow-sm"
                        :class="message.author.user_id === currentUserId ? 'ml-auto bg-primary text-primary-foreground' : 'bg-card text-foreground border'"
                      >
                        <div class="whitespace-pre-wrap break-words">{{ message.content }}</div>
                      </div>
                      <div
                        class="mt-1 px-1 text-[11px] text-muted-foreground"
                        :class="message.author.user_id === currentUserId ? 'text-right' : 'text-left'"
                      >
                        {{ new Date(message.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }}
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </ScrollArea>
          </div>

          <div class="relative z-20 border-t bg-background p-3">
            <div class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-full border bg-card/80 px-3 py-2 shadow-sm">
              <Input
                v-model="directMessageContent"
                :placeholder="t('chat.directMessage.placeholder', { user: directMessageStandaloneTarget.nickname })"
                class="h-11 min-w-0 border-0 bg-transparent px-1 py-0 leading-none shadow-none focus-visible:ring-0"
                @keydown="handleSendDirectMessageKeydown"
              />
              <AppSendButton
                :loading="isSendingDirectMessage"
                :disabled="isLoadingDirectMessages || isSendingDirectMessage || !directMessageContent.trim()"
                type="button"
                class="relative z-30 h-11 shrink-0 rounded-full px-4 pointer-events-auto"
                @click="submitStandaloneDirectMessage"
              >
                {{ isSendingDirectMessage ? t('common.processing') : t('chat.actions.sendMessage') }}
              </AppSendButton>
            </div>
          </div>
        </div>

        <ChatRoom
          v-else-if="activeChannel"
          :channel="activeChannel"
          :messages="messages"
          :members="members"
          :pinned-messages="pinnedMessages"
          :can-manage="canManage"
          :is-loading="isLoadingMessages"
          :is-sending="isSending"
          :current-user-id="currentUserId"
          :direct-messages="directMessages"
          :is-loading-direct-messages="isLoadingDirectMessages"
          :is-sending-direct-message="isSendingDirectMessage"
          :channels="chatChannels"
          @send="handleSendMessage"
          @load-more="handleLoadMore"
          @react="handleReact"
          @edit="handleEditMessage"
          @delete="handleDeleteMessage"
          @pin="handlePinMessage"
          @toggle-mute="() => handleToggleChannelMute()"
          @search="handleSearch"
          @view-profile="openMemberProfile"
          @open-direct-message="handleOpenDirectMessage"
          @open-direct-message-standalone="handleOpenDirectMessageStandalone"
          @send-direct-message="handleSendDirectMessage"
        />

        <div
          v-else
          class="h-full flex items-center justify-center text-muted-foreground"
        >
          {{ t('chat.empty.noChannels') }}
        </div>
      </template>
    </div>
  </div>
</template>
