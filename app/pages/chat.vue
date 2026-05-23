<script setup lang="ts">
import {
  computed,
  onBeforeUnmount,
  onMounted,
  ref,
  watch
} from 'vue';
import { toast } from 'vue-sonner';
import {
  Bell,
  BellOff,
  Copy,
  ArrowLeft,
  AlertTriangle,
  Hash,
  Inbox,
  Link,
  Loader2,
  Search,
  UserPlus
} from 'lucide-vue-next';
import ChatChannelList from '@/components/ChatChannelList.vue';
import ChatDirectConversationList from '@/components/ChatDirectConversationList.vue';
import ChatRoom from '@/components/ChatRoom.vue';
import GroupManageModal from '@/components/GroupManageModal.vue';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
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
  v2ListDirectConversations,
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
  mapV2DirectConversationMember,
  mapV2ChatGroup,
  mapV2ChatMember,
  mapV2ChatMessage,
  replaceChatMessage
} from '@/services/chat';
import type { ChatGroupVM } from '@/services/chat';
import { v2SearchUsers } from '@/services/users';
import { usePreferenceStore } from '@/stores/user';
import { resolveRealtimeUrl } from '@/utils/apiBase';
import type { Group } from '@/types/groups';
import type {
  V2CreateGroupInviteData,
  V2ChatMessage,
  V2DirectConversation,
  V2DirectMessage
} from '@/types/v2';
import type { PublicUserVM } from '@/types/users';

const { t } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();
const router = useRouter();
const LAST_CHAT_GROUP_STORAGE_PREFIX =
  'nekotribe.chat.lastGroupId';

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
const directConversations = ref<V2DirectConversation[]>([]);
const directMessages = ref<V2DirectMessage[]>([]);
const isLoadingDirectConversations = ref(false);
const isLoadingDirectMessages = ref(false);
const isSendingDirectMessage = ref(false);
const isMobileNavigationOpen = ref(true);

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
const canSendActiveChannel = computed(() => {
  const channel = activeChannel.value;
  if (!channel) return false;
  if (channel.type === 'text') return true;
  if (channel.type === 'announcement') return canManage.value;
  return false;
});
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
    ? t('chat.defaultCategoryName')
    : findCategoryName(createChannelCategoryId.value)
);
const canSubmitCreateChannel = computed(
  () =>
    createChannelName.value.trim().length > 0 &&
    !isCreatingChannel.value
);

function showMobileNavigation(): void {
  isMobileNavigationOpen.value = true;
}

function showMobileContent(): void {
  isMobileNavigationOpen.value = false;
}

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

function lastChatGroupStorageKey(): string {
  const userId = currentUserId.value;
  return `${LAST_CHAT_GROUP_STORAGE_PREFIX}:${
    Number.isFinite(userId) && userId > 0
      ? String(userId)
      : 'guest'
  }`;
}

function readLastChatGroupId(): number | null {
  if (!import.meta.client) return null;
  try {
    const raw = window.localStorage.getItem(
      lastChatGroupStorageKey()
    );
    const id = Number(raw);
    return Number.isInteger(id) && id > 0 ? id : null;
  } catch {
    return null;
  }
}

function writeLastChatGroupId(groupId: number): void {
  if (!import.meta.client) return;
  try {
    window.localStorage.setItem(
      lastChatGroupStorageKey(),
      String(groupId)
    );
  } catch {
    // Storage can be unavailable in private browsing or SSR-like previews.
  }
}

function forgetLastChatGroupId(groupId: number): void {
  if (readLastChatGroupId() !== groupId || !import.meta.client) {
    return;
  }
  try {
    window.localStorage.removeItem(lastChatGroupStorageKey());
  } catch {
    // Ignore storage failures; the chat can still fall back to the first group.
  }
}

function preferredChatGroup(): ChatGroupVM | null {
  const lastGroupId = readLastChatGroupId();
  return (
    (lastGroupId
      ? groups.value.find(group => group.id === lastGroupId)
      : null) ??
    groups.value[0] ??
    null
  );
}

function findCategoryName(categoryId: number): string {
  return (
    channelCategories.value.find(
      category => category.id === categoryId
    )?.name ?? t('chat.defaultCategoryName')
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
  forgetLastChatGroupId(groupId);
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

function sortDirectConversations(
  items: V2DirectConversation[]
): V2DirectConversation[] {
  return [...items].sort((a, b) => {
    const left = new Date(
      a.last_message?.created_at || a.updated_at
    ).getTime();
    const right = new Date(
      b.last_message?.created_at || b.updated_at
    ).getTime();
    return right - left;
  });
}

function upsertDirectConversation(
  conversation: V2DirectConversation
): void {
  const index = directConversations.value.findIndex(
    item => item.conversation_id === conversation.conversation_id
  );
  if (index === -1) {
    directConversations.value = sortDirectConversations([
      conversation,
      ...directConversations.value
    ]);
    return;
  }

  const updated = [...directConversations.value];
  updated[index] = conversation;
  directConversations.value = sortDirectConversations(updated);
}

function updateDirectConversationPreview(
  message: V2DirectMessage,
  isActiveConversation: boolean
): void {
  const index = directConversations.value.findIndex(
    item => item.conversation_id === message.conversation_id
  );
  if (index === -1) {
    void loadDirectConversations(false);
    return;
  }

  const current = directConversations.value[index];
  if (!current) return;

  const updated = [...directConversations.value];
  const isIncoming = message.author.user_id !== currentUserId.value;
  updated[index] = {
    ...current,
    unread_count:
      isIncoming && !isActiveConversation
        ? current.unread_count + 1
        : isActiveConversation
          ? 0
          : current.unread_count,
    last_message: {
      message_id: message.message_id,
      content: message.content,
      author_name:
        message.author.display_name || message.author.username,
      created_at: message.created_at
    },
    updated_at: message.updated_at || message.created_at
  };
  directConversations.value = sortDirectConversations(updated);
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
    payload.data?.direct_message
  ) {
    const directMessage = payload.data.direct_message;
    const isActiveConversation =
      directMessage.conversation_id === directConversationId.value;
    if (isActiveConversation) {
      upsertDirectMessage(directMessage);
    }
    updateDirectConversationPreview(
      directMessage,
      isActiveConversation
    );
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

  ws = new WebSocket(resolveRealtimeUrl());
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

async function loadDirectConversations(
  showLoading = true
): Promise<void> {
  if (showLoading) {
    isLoadingDirectConversations.value = true;
  }
  try {
    const result = await v2ListDirectConversations({
      page: 1,
      page_size: 50
    });
    directConversations.value = sortDirectConversations(
      result.items
    );
  } catch {
    toast.error(t('chat.feedback.loadDirectConversationsFailed'));
  } finally {
    if (showLoading) {
      isLoadingDirectConversations.value = false;
    }
  }
}

async function loadDirectMessagesForConversation(
  conversationId: number
): Promise<void> {
  directMessages.value = [];
  isLoadingDirectMessages.value = true;
  try {
    const result = await v2ListDirectMessages(conversationId, {
      page: 1,
      page_size: 50
    });
    directMessages.value = result.items;
    directConversations.value = directConversations.value.map(
      conversation =>
        conversation.conversation_id === conversationId
          ? { ...conversation, unread_count: 0 }
          : conversation
    );
  } catch {
    toast.error(t('chat.feedback.loadDirectMessagesFailed'));
  } finally {
    isLoadingDirectMessages.value = false;
  }
}

async function openDirectConversation(
  conversation: V2DirectConversation
): Promise<void> {
  upsertDirectConversation(conversation);
  directConversationId.value = conversation.conversation_id;
  directMessageTargetId.value = conversation.participant.user_id;
  directMessageStandaloneTarget.value =
    mapV2DirectConversationMember(conversation);
  directMessageContent.value = '';
  await loadDirectMessagesForConversation(
    conversation.conversation_id
  );
}

function directMessageQueryUserId(): number | null {
  const raw = route.query.dm;
  const value = Array.isArray(raw) ? raw[0] : raw;
  const id = Number(value ?? 0);
  return Number.isInteger(id) && id > 0 ? id : null;
}

function clearDirectMessageQuery(): void {
  if (!('dm' in route.query)) return;
  const query = { ...route.query };
  delete query.dm;
  void router.replace({
    path: route.path,
    query
  });
}

async function openDirectMessageFromQuery(): Promise<void> {
  const targetUserId = directMessageQueryUserId();
  if (!targetUserId) return;
  if (targetUserId === currentUserId.value) {
    toast.error(t('chat.feedback.cannotMessageSelf'));
    clearDirectMessageQuery();
    return;
  }

  try {
    const conversation = await v2CreateDirectConversation({
      target_user_id: targetUserId
    });
    await openDirectConversation(conversation);
    showMobileContent();
    await loadDirectConversations(false);
  } catch {
    toast.error(t('chat.feedback.loadDirectMessagesFailed'));
  } finally {
    clearDirectMessageQuery();
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
  writeLastChatGroupId(group.id);
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
    const [result] = await Promise.all([
      v2ListChatGroups({
        page: 1,
        page_size: 50
      }),
      loadDirectConversations()
    ]);
    groups.value = result.items.map(mapV2ChatGroup);
    const nextGroup = preferredChatGroup();
    if (nextGroup) {
      await loadGroup(nextGroup);
    }
    connectWs();
    await openDirectMessageFromQuery();
  } catch {
    errorMessage.value = t('chat.feedback.loadFailed');
  } finally {
    isLoading.value = false;
  }
}

async function handleSelectChannel(
  channel: Channel
): Promise<void> {
  exitDirectMessageView();
  showMobileContent();
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
  if (!group) return;

  exitDirectMessageView();

  if (group.id === activeGroup.value?.id) return;

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
  if (
    !activeChannel.value ||
    isSending.value ||
    !canSendActiveChannel.value
  ) {
    return;
  }
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

  try {
    const conversation = await v2CreateDirectConversation({
      target_user_id: member.id
    });
    directConversationId.value = conversation.conversation_id;
    upsertDirectConversation(conversation);
    await loadDirectMessagesForConversation(
      conversation.conversation_id
    );
  } catch {
    toast.error(t('chat.feedback.loadDirectMessagesFailed'));
  }
}

async function handleOpenDirectMessageStandalone(
  member: ChatMember
): Promise<void> {
  await handleOpenDirectMessage(member);
  directMessageContent.value = '';
  directMessageStandaloneTarget.value = member;
  showMobileContent();
}

async function handleSelectDirectConversation(
  conversation: V2DirectConversation
): Promise<void> {
  await openDirectConversation(conversation);
  showMobileContent();
}

function closeDirectMessageStandalone(): void {
  directMessageStandaloneTarget.value = null;
  showMobileNavigation();
}

function exitDirectMessageView(): void {
  directMessageStandaloneTarget.value = null;
  directMessageContent.value = '';
  directConversationId.value = null;
  directMessageTargetId.value = null;
  directMessages.value = [];
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
    updateDirectConversationPreview(created, true);
    void loadDirectConversations(false);
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

watch(
  () => route.query.dm,
  () => {
    if (!isLoading.value) {
      void openDirectMessageFromQuery();
    }
  }
);

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
  <div class="flex h-full min-h-0 w-full min-w-0 flex-col overflow-hidden md:flex-row">
    <div
      data-chat-nav-panel="true"
      class="h-full w-full min-w-0 flex-shrink-0 flex-col overflow-hidden border-b bg-muted/20 md:w-72 md:border-b-0 md:border-r"
      :class="isMobileNavigationOpen ? 'flex' : 'hidden md:flex'"
    >
      <div class="flex h-full min-h-0 flex-col">
        <div class="h-64 shrink-0 max-md:h-[30dvh] max-md:min-h-44 max-md:max-h-72">
          <ChatDirectConversationList
            :conversations="directConversations"
            :active-conversation-id="directConversationId"
            :is-loading="isLoadingDirectConversations"
            @select="handleSelectDirectConversation"
            @view-profile="openMemberProfile"
          />
        </div>
        <div class="min-h-0 flex-1 border-t">
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
      </div>
    </div>

    <Dialog v-model:open="createChannelDialogOpen">
      <DialogContent
        class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-md"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
        >
          <DialogTitle class="flex items-center gap-2 text-base">
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
            >
              <Hash class="h-4 w-4" />
            </span>
            {{ t('chat.dialogs.createChannel.title') }}
          </DialogTitle>
          <DialogDescription class="text-xs text-muted-foreground">
            {{
              t('chat.dialogs.createChannel.description', {
                category: createChannelCategoryName
              })
            }}
          </DialogDescription>
        </DialogHeader>

        <form
          class="grid gap-4 px-5 py-4"
          @submit.prevent="submitCreateChannel"
        >
          <div class="grid gap-2">
            <Label
              for="create-channel-name"
              class="text-xs font-medium"
            >
              {{ t('chat.dialogs.createChannel.nameLabel') }}
            </Label>
            <Input
              id="create-channel-name"
              v-model="createChannelName"
              :placeholder="t('chat.prompts.channelName')"
              :disabled="isCreatingChannel"
              maxlength="64"
              autocomplete="off"
              class="h-9 shadow-xs"
            />
          </div>

          <DialogFooter
            class="-mx-5 -mb-4 mt-1 border-t border-border/60 bg-background/60 px-5 py-3"
          >
            <Button
              type="button"
              variant="outline"
              size="sm"
              class="h-9 rounded-md shadow-xs"
              :disabled="isCreatingChannel"
              @click="createChannelDialogOpen = false"
            >
              {{ t('common.cancel') }}
            </Button>
            <Button
              type="submit"
              size="sm"
              class="h-9 rounded-md shadow-xs"
              :disabled="!canSubmitCreateChannel"
            >
              <Loader2
                v-if="isCreatingChannel"
                class="h-3.5 w-3.5 animate-spin"
              />
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
      <DialogContent
        class="flex max-h-[calc(100dvh-1rem)] flex-col overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-2xl"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
        >
          <DialogTitle class="flex items-center gap-2 text-base">
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
            >
              <UserPlus class="h-4 w-4" />
            </span>
            {{ t('chat.invite.title') }}
          </DialogTitle>
          <DialogDescription class="text-xs text-muted-foreground">
            {{
              t('chat.invite.description', {
                group: activeGroup?.name || t('chat.groupFallbackName')
              })
            }}
          </DialogDescription>
        </DialogHeader>

        <div
          class="grid flex-1 gap-5 overflow-y-auto px-4 py-4 sm:px-5 md:grid-cols-[1.15fr_0.85fr]"
        >
          <div class="grid gap-4">
            <div class="grid gap-2">
              <Label
                for="chat-invite-search"
                class="text-xs font-medium"
              >
                {{ t('chat.invite.searchLabel') }}
              </Label>
              <div class="relative">
                <Search
                  class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
                />
                <Input
                  id="chat-invite-search"
                  v-model="inviteSearchQuery"
                  class="h-9 pl-9 shadow-xs"
                  :placeholder="t('chat.invite.searchPlaceholder')"
                  autocomplete="off"
                  @input="handleInviteSearchInput"
                />
              </div>
              <p class="text-[11px] text-muted-foreground">
                {{ t('chat.invite.searchHint') }}
              </p>
            </div>

            <div
              v-if="selectedInvitee"
              class="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/30 p-3"
            >
              <div class="flex min-w-0 items-center gap-3">
                <Avatar class="h-9 w-9 ring-1 ring-border/60">
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
                class="h-8 rounded-md"
                @click="selectedInvitee = null"
              >
                {{ t('chat.invite.clearSelection') }}
              </Button>
            </div>

            <ScrollArea
              class="h-64 rounded-lg border border-border/60 bg-card"
            >
              <div class="p-2">
                <div
                  v-if="isSearchingInviteUsers"
                  class="flex items-center justify-center gap-2 p-6 text-center text-sm text-muted-foreground"
                >
                  <Loader2 class="h-3.5 w-3.5 animate-spin" />
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
                  class="h-auto w-full justify-start gap-3 rounded-md p-2 text-left"
                  :class="{
                    'bg-muted': selectedInvitee?.id === user.id
                  }"
                  @click="selectInvitee(user)"
                >
                  <Avatar class="h-9 w-9 ring-1 ring-border/60">
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
                  <span
                    v-if="selectedInvitee?.id === user.id"
                    class="inline-flex items-center rounded-full border border-emerald-200/60 bg-emerald-100/60 px-2 py-0.5 text-[10px] font-medium text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300"
                  >
                    {{ t('chat.invite.selected') }}
                  </span>
                </Button>
              </div>
            </ScrollArea>
          </div>

          <div class="grid gap-4">
            <section
              class="rounded-lg border border-border/60 bg-card p-4 shadow-none"
            >
              <div class="flex items-center gap-2 text-sm font-medium">
                <span
                  class="flex h-7 w-7 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
                >
                  <Link class="h-3.5 w-3.5" />
                </span>
                {{ t('chat.invite.linkTitle') }}
              </div>
              <p class="mt-2 text-xs text-muted-foreground">
                {{ t('chat.invite.linkDescription') }}
              </p>
            </section>

            <div class="grid grid-cols-2 gap-3">
              <div class="grid gap-2">
                <Label
                  for="chat-invite-max-uses"
                  class="text-xs font-medium"
                >
                  {{ t('chat.invite.maxUses') }}
                </Label>
                <Input
                  id="chat-invite-max-uses"
                  v-model.number="inviteMaxUses"
                  type="number"
                  min="1"
                  class="h-9 shadow-xs"
                  :disabled="!!selectedInvitee"
                />
              </div>
              <div class="grid gap-2">
                <Label
                  for="chat-invite-expire-hours"
                  class="text-xs font-medium"
                >
                  {{ t('chat.invite.expireHours') }}
                </Label>
                <Input
                  id="chat-invite-expire-hours"
                  v-model.number="inviteExpireHours"
                  type="number"
                  min="1"
                  class="h-9 shadow-xs"
                />
              </div>
            </div>

            <div class="grid gap-2">
              <Label
                for="chat-invite-message"
                class="text-xs font-medium"
              >
                {{ t('chat.invite.messageLabel') }}
              </Label>
              <Textarea
                id="chat-invite-message"
                v-model="inviteMessage"
                class="min-h-24 resize-none shadow-xs"
                :placeholder="t('chat.invite.messagePlaceholder')"
                maxlength="200"
              />
            </div>

            <section
              v-if="createdInvite"
              class="rounded-lg border border-emerald-200/60 bg-emerald-50/40 p-3 shadow-none dark:border-emerald-900/40 dark:bg-emerald-950/20"
            >
              <div class="text-sm font-medium text-emerald-800 dark:text-emerald-200">
                {{ t('chat.invite.createdTitle') }}
              </div>
              <div
                v-if="inviteUrl(createdInvite)"
                class="mt-2 flex items-center gap-2"
              >
                <Input
                  :model-value="inviteUrl(createdInvite) || ''"
                  readonly
                  class="h-8 text-xs shadow-xs"
                />
                <Button
                  size="icon"
                  variant="outline"
                  class="h-8 w-8 shrink-0 rounded-md shadow-xs"
                  @click="copyCreatedInvite"
                >
                  <Copy class="h-3.5 w-3.5" />
                </Button>
              </div>
              <p
                v-else
                class="mt-2 text-xs text-emerald-700/80 dark:text-emerald-300/80"
              >
                {{ t('chat.invite.targetedCreated') }}
              </p>
            </section>
          </div>
        </div>

        <DialogFooter
          class="border-t border-border/60 bg-background/60 px-5 py-3"
        >
          <Button
            type="button"
            variant="outline"
            size="sm"
            class="h-9 rounded-md shadow-xs"
            :disabled="isCreatingInvite"
            @click="inviteDialogOpen = false"
          >
            {{ t('common.cancel') }}
          </Button>
          <Button
            type="button"
            size="sm"
            class="h-9 rounded-md shadow-xs"
            :disabled="isCreatingInvite || !activeGroup"
            @click="submitInvite"
          >
            <Loader2
              v-if="isCreatingInvite"
              class="h-3.5 w-3.5 animate-spin"
            />
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
      <DialogContent
        class="flex max-h-[calc(100dvh-1rem)] flex-col overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-lg"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
        >
          <DialogTitle class="flex items-center gap-2 text-base">
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
            >
              <Bell class="h-4 w-4" />
            </span>
            {{ t('chat.notifications.groupTitle') }}
          </DialogTitle>
          <DialogDescription class="text-xs text-muted-foreground">
            {{
              t('chat.notifications.groupDescription', {
                group: activeGroup?.name || t('chat.groupFallbackName')
              })
            }}
          </DialogDescription>
        </DialogHeader>

        <ScrollArea class="max-h-[56vh] flex-1 px-5 py-4">
          <div class="grid gap-2 pr-2">
            <div
              v-if="chatChannels.length === 0"
              class="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border/60 bg-muted/20 p-8 text-center text-sm text-muted-foreground"
            >
              <span
                class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
              >
                <BellOff class="h-5 w-5" />
              </span>
              {{ t('chat.notifications.noChannels') }}
            </div>
            <div
              v-for="channel in chatChannels"
              :key="channel.id"
              class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-card p-3 shadow-none"
            >
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <span
                    :class="[
                      'flex h-7 w-7 items-center justify-center rounded-md',
                      channel.isMuted
                        ? 'bg-muted/60 text-muted-foreground'
                        : 'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400'
                    ]"
                  >
                    <component
                      :is="channel.isMuted ? BellOff : Bell"
                      class="h-3.5 w-3.5"
                    />
                  </span>
                  <span class="truncate text-sm font-medium">
                    # {{ channel.name }}
                  </span>
                </div>
                <p class="mt-1 text-[11px] text-muted-foreground">
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
            </div>
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

    <div
      data-chat-content-panel="true"
      class="h-full min-h-0 flex-1 min-w-0 overflow-hidden"
      :class="isMobileNavigationOpen ? 'hidden md:block' : 'block'"
    >
      <div
        v-if="isLoading"
        class="flex h-full flex-col items-center justify-center gap-3 text-sm text-muted-foreground"
      >
        <Loader2 class="h-5 w-5 animate-spin" />
        {{ t('common.loading') }}
      </div>
      <div
        v-else-if="errorMessage"
        class="flex h-full items-center justify-center p-6"
      >
        <div
          class="flex max-w-md flex-col items-center gap-3 rounded-lg border border-dashed border-rose-200/60 bg-rose-50/40 p-8 text-center dark:border-rose-900/40 dark:bg-rose-950/20"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 text-rose-600 ring-1 ring-rose-200/60 dark:text-rose-400 dark:ring-rose-900/40"
          >
            <AlertTriangle class="h-5 w-5" />
          </span>
          <p class="text-sm text-rose-800 dark:text-rose-200">
            {{ errorMessage }}
          </p>
          <Button
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
            @click="loadChat"
          >
            {{ t('common.refresh') }}
          </Button>
        </div>
      </div>
      <div
        v-else-if="!activeGroup && !isDirectMessageStandalone"
        class="flex h-full items-center justify-center p-6"
      >
        <div
          class="flex max-w-md flex-col items-center gap-3 rounded-lg border border-dashed border-border/60 bg-muted/20 p-8 text-center text-sm text-muted-foreground"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
          >
            <Inbox class="h-5 w-5" />
          </span>
          {{
            directConversations.length > 0
              ? t('chat.empty.selectDirectConversation')
              : t('chat.empty.noGroups')
          }}
        </div>
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
              <span class="sr-only">{{ t('chat.backToChannels') }}</span>
            </Button>

            <Button
              type="button"
              variant="ghost"
              size="icon"
              class="h-10 w-10 shrink-0 rounded-full p-0"
              @click="
                openMemberProfile(directMessageStandaloneTarget.id)
              "
            >
              <Avatar class="h-10 w-10 ring-1 ring-border">
                <AvatarImage
                  :src="directMessageStandaloneTarget.avatar"
                  :alt="directMessageStandaloneTarget.nickname"
                />
                <AvatarFallback>
                  {{ directMessageStandaloneTarget.nickname.slice(0, 2) }}
                </AvatarFallback>
              </Avatar>
            </Button>

            <div class="min-w-0 flex-1">
              <div class="truncate text-base font-semibold leading-6">
                {{ directMessageStandaloneTarget.nickname }}
              </div>
              <div class="truncate text-sm text-muted-foreground">
                @{{ directMessageStandaloneTarget.username }}
              </div>
            </div>

            <span
              class="inline-flex items-center gap-1 rounded-full border border-sky-200/60 bg-sky-100/60 px-2 py-0.5 text-[11px] font-medium text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300"
            >
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
                        class="rounded-xl border px-4 py-3 text-sm leading-6 shadow-xs"
                        :class="
                          message.author.user_id === currentUserId
                            ? 'ml-auto border-primary/60 bg-primary text-primary-foreground'
                            : 'border-border/70 bg-muted text-foreground dark:bg-muted/80'
                        "
                      >
                        <div class="whitespace-pre-wrap break-words">
                          {{ message.content }}
                        </div>
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
          :show-mobile-navigation-toggle="true"
          @send="handleSendMessage"
          @load-more="handleLoadMore"
          @react="handleReact"
          @edit="handleEditMessage"
          @delete="handleDeleteMessage"
          @pin="handlePinMessage"
          @toggle-mute="() => handleToggleChannelMute()"
          @search="handleSearch"
          @show-navigation="showMobileNavigation"
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
