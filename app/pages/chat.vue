<script setup lang="ts">
import { useMessageArrivals } from '@/composables/useMessageArrivals';
import {
  computed,
  onBeforeUnmount,
  onMounted,
  ref,
  shallowReactive,
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
  Phone,
  Search,
  UserPlus,
  Video
} from 'lucide-vue-next';
import ChatChannelList from '@/components/ChatChannelList.vue';
import ChatDirectConversationList from '@/components/ChatDirectConversationList.vue';
import UserAvatar from '@/components/UserAvatar.vue';
import { notificationTargetId } from '@/utils/post-notification-target';
import ChatRoom from '@/components/ChatRoom.vue';
import ChatInput from '@/components/ChatInput.vue';
import ChatMessage from '@/components/ChatMessage.vue';
import ChatSearchFilters from '@/components/ChatSearchFilters.vue';
import { useCommandChatSearch } from '@/composables/useCommandChatSearch';
import { authQueueFor } from '@/services/auth-request-queue';
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
import type {
  Channel,
  ChannelCategory
} from '@/components/ChatChannelList.vue';
import type { ChatMessageType } from '@/components/ChatMessage.vue';
import type { ChatMember } from '@/components/ChatMemberList.vue';
import {
  isDirectMessageForConversation,
  v2CreateChatChannel,
  v2CreateChatMessage,
  v2CreateDirectConversation,
  v2CreateDirectMessage,
  v2CreateChatReaction,
  v2CreateGroupInvite,
  v2DeleteChatChannel,
  v2DeleteChatMessage,
  v2DeleteDirectMessage,
  v2DeleteChatReaction,
  v2ListChatChannels,
  v2ListChatGroups,
  v2ListChatMembers,
  v2ListChatMessages,
  v2ListDirectConversations,
  v2ListDirectMessages,
  v2GetDirectReadStatus,
  v2ReadDirectMessage,
  v2SetDirectReadStatus,
  v2SetDirectMessageReaction,
  v2SetChatChannelMuteStatus,
  v2SetChatReadStatus,
  v2SetChatMessagePinStatus,
  v2UpdateChatChannel,
  v2UpdateChatMessage,
  v2UploadMedia
} from '@/api/v2';
import type { ChatMessageFilters } from '@/api/v2/chat';
import type { CallMode } from '@/api/v2/webrtc';
import { getGroup } from '@/services/groups';
import {
  buildChatChannelCategories,
  mapV2DirectConversationMember,
  mapV2DirectMessage,
  mapV2ChatGroup,
  mapV2ChatMember,
  mapV2ChatMessage,
  mergeDirectMessages,
  reconcileDirectHistory,
  replaceChatMessage
} from '@/services/chat';
import type { ChatGroupVM } from '@/services/chat';
import { v2SearchUsers } from '@/services/users';
import { groupInviteeId, normalizeGroupInviteCode } from '@/utils/group-invite';
import { usePreferenceStore } from '@/stores/user';
import { useRealtimeSocket } from '@/composables/useRealtimeSocket';
import { useChatTyping } from '@/composables/useChatTyping';
import { useDirectMessageViewport } from '@/composables/useDirectMessageViewport';
import { useWebRtcCalls } from '@/composables/useWebRtcCalls';
import type { RealtimeMessage } from '@/composables/useRealtimeSocket';
import type { Group } from '@/types/groups';
import type {
  V2CreateGroupInviteData,
  V2ChatMessage,
  V2DirectConversation,
  V2DirectMessage,
  V2DirectReadStatus
} from '@/types/v2';
import type { PublicUserVM } from '@/types/users';
import { confirmedChatUnread, displayedChatCursor } from '@/utils/chat-channel-read';
import { isPrivateMediaContent } from '@/utils/private-media';

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
    code?: string;
    room?: string;
    channel_id?: number;
    conversation_id?: number;
    message_id?: number;
    user_id?: number;
    online_status?: 'online' | 'offline' | 'hidden';
    last_seen_at?: string | null;
    message?: V2ChatMessage;
    viewer_neutral?: boolean;
    direct_message?: V2DirectMessage;
  };
}

const preferenceStore = usePreferenceStore();
const realtime = useRealtimeSocket();
const calls = useWebRtcCalls();
const app = useNuxtApp();
const commandSearch = useCommandChatSearch();
const commandAuth = authQueueFor(app);
const groups = ref<ChatGroupVM[]>([]);
const groupPage = ref(1);
const hasMoreGroups = ref(false);
const loadingMoreGroups = ref(false);
const activeGroup = ref<ChatGroupVM | null>(null);
const loadingGroupChannels = ref(false);
const channelLoadFailed = ref(false);
const channelCategories = ref<ChannelCategory[]>([]);
const muteRequests = shallowReactive(new Map<number, AbortController>());
const confirmedMutes = new Map<number, { muted: boolean; revision: number }>();
let muteRevision = 0;
let channelsRequest = 0;
const isMutePending = (channelId: number) => muteRequests.has(channelId);
const activeChannel = ref<Channel | null>(null);
const members = ref<ChatMember[]>([]);
const messages = ref<ChatMessageType[]>([]);
const isLoading = ref(true);
const isLoadingMessages = ref(false);
const failedMessageLoad = ref<boolean | null>(null);
const isSending = ref(false);
const channelComposerRevision = ref(0);
let uploadedChannelAttachments = new WeakMap<File, { id: number; authRevision: number }>();
let channelAttachmentUpload: AbortController | null = null;
const channelWriteBusy = ref(false);
let channelWriteRevision = 0;
const errorMessage = ref('');
const messagePage = ref(1);
const hasMoreMessages = ref(false);
const channelSearch = ref<ChatMessageFilters | null>(null);
let channelReadTimer: ReturnType<typeof setTimeout> | undefined;
let pendingChannelRead = 0;
let channelReadReceipt = 0;
let syncingChannelRead = false;
const createChannelDialogOpen = ref(false);
const editingChannelId = ref<number | null>(null);
const createChannelName = ref('');
const channelCategory = ref('');
const channelPrivate = ref(false);
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
const inviteResultUnknown = ref(false);
const pendingInvitee = computed(() => groupInviteeId(inviteSearchQuery.value, selectedInvitee.value?.id));
const notificationSettingsOpen = ref(false);
const groupSettingsOpen = ref(false);
const groupSettingsModel = ref<Group | null>(null);
const directConversationId = ref<number | null>(null);
const directMessageTargetId = ref<number | null>(null);
const directMessageStandaloneTarget = ref<ChatMember | null>(null);
const directSearch = ref<ChatMessageFilters | null>(null);
const standaloneDirectSearchOpen = ref(false);
const standaloneDirectReplyId = ref<number | null>(null);
const standaloneDirectReply = computed(() => {
  const message = directMessages.value.find(item => item.message_id === standaloneDirectReplyId.value);
  return message ? mapV2DirectMessage(message) : null;
});
let directAttachmentUpload: AbortController | null = null;
let directSelectionRevision = 0;
let directLinkRequest = 0;
const directLinkStatus = ref<'loading' | 'failed' | null>(null);
const directConversations = ref<V2DirectConversation[]>([]);
const directListPage = ref(1);
const hasMoreDirectConversations = ref(false);
let requestedDirectListPage = 1;
const directMessages = ref<V2DirectMessage[]>([]);
const directHistoryPage = ref(1);
const hasOlderDirectMessages = ref(false);
const loadingOlderDirectMessages = ref(false);
const isLoadingDirectConversations = ref(false);
const isLoadingDirectMessages = ref(false);
let directReadTimer: ReturnType<typeof setTimeout> | undefined;
let pendingDirectRead = 0;
let activeDirectReadWrite: number | null = null;
let directReadRequest = 0;
const directReadStatus = ref<V2DirectReadStatus | null>(null);
const standaloneDirectList = ref<HTMLElement | null>(null);
const directSheetOpen = ref(false);
const isSendingDirectMessage = ref(false);
const isMobileNavigationOpen = ref(true);

const currentUserId = computed(
  () => preferenceStore.preferences.user.id
);
const channelTyping = useChatTyping('channel_id', () => activeChannel.value?.id, () => currentUserId.value, realtime.send);
const directTyping = useChatTyping('conversation_id', () => directConversationId.value, () => currentUserId.value, realtime.send);
const lastSeenOwnDirectMessage = computed(() => {
  const through = directReadStatus.value?.participant_last_read_message_id ?? 0;
  return directMessages.value.reduce((latest, message) => message.author.user_id === currentUserId.value &&
    message.message_id <= through ? Math.max(latest, message.message_id) : latest, 0);
});
useDirectMessageViewport(standaloneDirectList, () => directMessages.value.map(item => item.message_id).join(','),
  () => directMessageStandaloneTarget.value !== null && directSearch.value === null, markVisibleDirectMessage);
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
const channelEncoder = new TextEncoder();
const channelNameBytes = computed(() => channelEncoder.encode(createChannelName.value.trim()).length);
const channelCategoryBytes = computed(() => channelEncoder.encode(channelCategory.value.trim()).length);
const canSubmitCreateChannel = computed(
  () =>
    channelNameBytes.value > 0 && channelNameBytes.value <= 100 &&
    channelCategoryBytes.value <= 50 && !channelWriteBusy.value
);

function showMobileNavigation(): void {
  isMobileNavigationOpen.value = true;
}

function showMobileContent(): void {
  isMobileNavigationOpen.value = false;
}

let unsubscribeRealtime: (() => void) | undefined;
let joinedChannel: number | null = null;
let disposed = false;
let messageRequest = 0;
let groupRequest = 0;
let conversationRequest = 0;
let conversationListRequest = 0;
let chatRequest = 0;
let inviteSearchTimer: ReturnType<typeof setTimeout> | null =
  null;
let inviteSearchRequest: AbortController | undefined;
let inviteSubmitRequest: AbortController | undefined;

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
  const code = normalizeGroupInviteCode(invite?.invite_code);
  return code ? absoluteUrl(`/groups/invite/${code}`) : null;
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
  if (!activeGroup.value || inviteDialogOpen.value) return;
  inviteSearchQuery.value = '';
  inviteMessage.value = '';
  inviteDialogOpen.value = true;
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
  loadingGroupChannels.value = false;
  channelLoadFailed.value = false;
  channelCategories.value = [];
  messages.value = [];
  members.value = [];
  const next = groups.value[0];
  if (next) {
    void loadGroup(next);
  }
}

function syncChatChannel(ready: boolean, channelId: number | null): void {
  if (!ready) {
    joinedChannel = null;
    return;
  }
  if (joinedChannel === channelId) return;
  if (joinedChannel !== null) {
    realtime.send({type: 'chat_leave_channel', data: {channelId: joinedChannel}});
    joinedChannel = null;
  }
  if (channelId !== null &&
      realtime.send({type: 'chat_join_channel', data: {channelId}})) {
    joinedChannel = channelId;
  }
}

let liveChannelChanges: Map<number, ChatMessageType | null> | null = null;
const pendingChannelReactions = new Set<number>();

function upsertMessage(message: ChatMessageType): void {
  if (liveChannelChanges?.get(message.id) === null) return;
  liveChannelChanges?.set(message.id, message);
  messages.value = replaceChatMessage(messages.value, message);
}

function removeChannelMessage(messageId: number): void {
  liveChannelChanges?.set(messageId, null);
  messages.value = messages.value.filter(message => message.id !== messageId);
}

let liveDirectChanges: Map<number, V2DirectMessage | null> | null = null;
const pendingDirectReactions = new Map<number, boolean>();
const directMessageRefreshes = new Map<number, AbortController>();
const directDeleteTarget = ref<V2DirectMessage | null>(null);
const deletingDirect = ref(false);

function canDeleteDirectMessage(message: V2DirectMessage): boolean {
  return message.conversation_id === directConversationId.value &&
    message.author.user_id === currentUserId.value && message.can_delete && !message.is_deleted;
}

function requestDirectDelete(message: V2DirectMessage): void {
  if (!deletingDirect.value && canDeleteDirectMessage(message)) directDeleteTarget.value = message;
}

function closeDirectDelete(): void {
  directDeleteTarget.value = null;
  deletingDirect.value = false;
}

async function confirmDirectDelete(): Promise<void> {
  const message = directDeleteTarget.value;
  if (!message || deletingDirect.value || !canDeleteDirectMessage(message)) return;
  const ownsPage = captureChatOwner();
  const current = () => ownsPage() && directDeleteTarget.value === message &&
    directConversationId.value === message.conversation_id;
  deletingDirect.value = true;
  try {
    await v2DeleteDirectMessage(message.conversation_id, message.message_id);
    if (!current()) return;
    removeDirectMessage(message.message_id);
    hideDeletedDirectPreview(message.conversation_id, message.message_id);
    closeDirectDelete();
    void loadDirectConversations(false);
  } catch {
    if (current()) toast.error(t('chat.feedback.deleteFailed'));
  } finally {
    if (current()) deletingDirect.value = false;
  }
}

function upsertDirectMessage(message: V2DirectMessage): void {
  if (liveDirectChanges?.get(message.message_id) === null) return;
  liveDirectChanges?.set(message.message_id, message);
  directMessages.value = mergeDirectMessages(directMessages.value, [message]);
}

function removeDirectMessage(messageId: number): void {
  liveDirectChanges?.set(messageId, null);
  directMessageRefreshes.get(messageId)?.abort();
  directMessageRefreshes.delete(messageId);
  if (standaloneDirectReplyId.value === messageId) standaloneDirectReplyId.value = null;
  directMessages.value = directMessages.value.flatMap(message => {
    if (message.message_id === messageId) return [];
    if (message.reply_to?.message_id !== messageId) return [message];
    const updated = { ...message, reply_to: undefined };
    liveDirectChanges?.set(message.message_id, updated);
    return [updated];
  });
}

async function refreshDirectMessage(conversationId: number, messageId: number): Promise<void> {
  const owner = captureChatOwner();
  const selection = directSelectionRevision;
  const current = () => owner() && selection === directSelectionRevision &&
    directConversationId.value === conversationId &&
    directMessages.value.some(message => message.message_id === messageId);
  if (!current()) return;
  if (pendingDirectReactions.has(messageId)) {
    pendingDirectReactions.set(messageId, true);
    return;
  }
  directMessageRefreshes.get(messageId)?.abort();
  const request = new AbortController();
  directMessageRefreshes.set(messageId, request);
  try {
    const updated = await v2ReadDirectMessage(conversationId, messageId, request.signal);
    if (current() && directMessageRefreshes.get(messageId) === request) upsertDirectMessage(updated);
  } catch {
    // A deleted or no-longer-visible message may disappear during the refresh.
  } finally {
    if (directMessageRefreshes.get(messageId) === request) directMessageRefreshes.delete(messageId);
  }
}

async function handleDirectReaction(messageId: number, emoji: string): Promise<void> {
  const message = directMessages.value.find(item => item.message_id === messageId);
  if (!message || pendingDirectReactions.has(messageId)) return;
  const owner = captureChatOwner();
  const selection = directSelectionRevision;
  const current = () => owner() && selection === directSelectionRevision &&
    directConversationId.value === message.conversation_id;
  if (!current()) return;
  directMessageRefreshes.get(messageId)?.abort();
  directMessageRefreshes.delete(messageId);
  pendingDirectReactions.set(messageId, false);
  try {
    const reacted = message.reactions?.some(item => item.emoji === emoji && item.reacted_by_me) ?? false;
    const updated = await v2SetDirectMessageReaction(message.conversation_id, messageId, emoji, !reacted);
    if (current() && directMessages.value.some(item => item.message_id === messageId)) upsertDirectMessage(updated);
  } catch {
    if (current()) toast.error(t('chat.feedback.reactionFailed'));
  } finally {
    if (current()) {
      const refresh = pendingDirectReactions.get(messageId);
      pendingDirectReactions.delete(messageId);
      if (refresh) void refreshDirectMessage(message.conversation_id, messageId);
    }
  }
}

function hideDeletedDirectPreview(conversationId: number, messageId: number): void {
  directConversations.value = directConversations.value.map(conversation =>
    conversation.conversation_id === conversationId && conversation.last_message?.message_id === messageId
      ? {...conversation, last_message: null}
      : conversation
  );
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
    if (directListPage.value !== 1) return;
    const next = sortDirectConversations([
      conversation,
      ...directConversations.value
    ]);
    if (next.length > 20) hasMoreDirectConversations.value = true;
    directConversations.value = next.slice(0, 20);
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
  if (current.last_message) {
    if (message.message_id === current.last_message.message_id) return;
    const timeDifference = Date.parse(message.created_at) - Date.parse(current.last_message.created_at);
    if (timeDifference < 0 || (timeDifference === 0 && message.message_id < current.last_message.message_id)) return;
  }

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
  if (directListPage.value > 1) void loadDirectConversations(false);
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
    if (!isActiveChannel) {
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
          lastSeenAt: lastSeenAt === undefined ? member.lastSeenAt : lastSeenAt
        }
      : member
  );
  if (directMessageStandaloneTarget.value?.id === userId) {
    directMessageStandaloneTarget.value = {
      ...directMessageStandaloneTarget.value,
      status: onlineStatus === 'online' ? 'online' : 'offline',
      lastSeenAt:
        lastSeenAt === undefined ? directMessageStandaloneTarget.value.lastSeenAt : lastSeenAt
    };
  }
}

function handleWsMessage(event: RealtimeMessage): void {
  if (event.type === 'typing_start' || event.type === 'typing_stop') {
    channelTyping.receive(event);
    directTyping.receive(event);
    return;
  }
  if (event.type === 'direct_read_updated') {
    const conversationId = event.data?.conversation_id;
    const reader = event.data?.reader_id;
    if (typeof conversationId === 'number' && Number.isSafeInteger(conversationId) && conversationId > 0 &&
        (conversationId === directConversationId.value || reader === currentUserId.value)) {
      void refreshDirectReadStatus(conversationId);
    }
    return;
  }
  const payload: ChatWsEvent = event;
  const channelId = payload.data?.channel_id;
  if (payload.type === 'system_notification' && payload.data?.code === 'chat_channel_ready') {
    if (channelId !== undefined && joinedChannel === channelId && activeChannel.value?.id === channelId &&
        payload.data.room === `chat:channel:${channelId}`) {
      void app.runWithContext(() => loadMessages(channelId));
    }
    return;
  }
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
    const existing = isActiveChannel ? messages.value.find(message => message.id === vm.id) : undefined;
    if (isActiveChannel && !channelSearch.value) {
      if (payload.data.viewer_neutral === true) {
        vm.canPin = canManage.value;
        vm.canDelete = canManage.value || vm.author.id === currentUserId.value;
        const reacted = new Set(existing?.reactions?.filter(reaction => reaction.reacted).map(reaction => reaction.emoji));
        for (const reaction of vm.reactions ?? []) reaction.reacted = reacted.has(reaction.emoji);
      }
      if (payload.type !== 'chat_reaction_updated') upsertMessage(vm);
      else if (existing) upsertMessage({ ...existing, reactions: vm.reactions });
    }
    if (payload.type === 'chat_message') {
      const own = vm.author.id === currentUserId.value;
      updateChannelPreview(payload.data.message, own || Boolean(existing));
      if (channelId && isActiveChannel && !own && !existing && !channelSearch.value) {
        pendingChannelRead = Math.max(pendingChannelRead, vm.id);
        scheduleChannelRead();
      }
    }
    return;
  }

  if (payload.type === 'direct_message_updated') {
    const { conversation_id: conversationId, message_id: messageId } = payload.data ?? {};
    if (typeof conversationId === 'number' && Number.isSafeInteger(conversationId) && conversationId > 0 &&
        typeof messageId === 'number' && Number.isSafeInteger(messageId) && messageId > 0) {
      void refreshDirectMessage(conversationId, messageId);
    }
    return;
  }

  if (
    payload.type === 'direct_message_deleted' && Number.isSafeInteger(payload.data?.conversation_id) &&
    Number.isSafeInteger(payload.data?.message_id)
  ) {
    const conversationId = payload.data?.conversation_id ?? 0;
    const messageId = payload.data?.message_id ?? 0;
    if (conversationId <= 0 || messageId <= 0) return;
    if (directConversationId.value === conversationId) {
      removeDirectMessage(messageId);
      if (directDeleteTarget.value?.message_id === messageId) closeDirectDelete();
    }
    hideDeletedDirectPreview(conversationId, messageId);
    void loadDirectConversations(false);
    return;
  }

  if (payload.type === 'direct_message') {
    const directMessage = payload.data?.direct_message;
    if (!isDirectMessageForConversation(payload.data?.conversation_id, directMessage)) return;
    const isActiveConversation =
      directMessage.conversation_id === directConversationId.value;
    if (isActiveConversation && !directSearch.value) {
      upsertDirectMessage(directMessage);
    }
    updateDirectConversationPreview(
      directMessage,
      isActiveConversation && directMessage.author.user_id === currentUserId.value
    );
    return;
  }

  if (
    payload.type === 'chat_message_deleted' &&
    payload.data?.message_id
  ) {
    if (isActiveChannel) {
      removeChannelMessage(payload.data.message_id);
    }
    if (channelId !== undefined && allChannels().some(channel => channel.id === channelId)) {
      void refreshChannels().catch(() => undefined);
    }
  }
}

function captureChatOwner(): () => boolean {
  const owner = realtime.ownerRevision.value;
  const authRevision = preferenceStore.authRevision();
  return () => !disposed && realtime.ownerRevision.value === owner &&
    preferenceStore.isAuthCurrent(authRevision);
}

function isVisibleChannel(channelId: number): boolean {
  return activeChannel.value?.id === channelId && directConversationId.value === null &&
    directMessageStandaloneTarget.value === null && !channelSearch.value &&
    document.visibilityState === 'visible' &&
    (!isMobileNavigationOpen.value || window.matchMedia('(min-width: 768px)').matches);
}

async function acknowledgeDisplayedChannel(
  channelId: number, cursor: number, current: () => boolean
): Promise<void> {
  if (!cursor || !current() || !isVisibleChannel(channelId)) return;
  const request = ++channelReadReceipt;
  try {
    const receipt = await app.runWithContext(() => v2SetChatReadStatus(channelId, cursor));
    if (!current() || request !== channelReadReceipt || pendingChannelRead > cursor || !isVisibleChannel(channelId)) return;
    const unread = confirmedChatUnread(channelId, cursor, receipt);
    if (unread === null) return;
    const channel = allChannels().find(item => item.id === channelId);
    if (channel) channel.unreadCount = unread;
    if (activeChannel.value?.id === channelId) activeChannel.value.unreadCount = unread;
  } catch {
    // Keep the server's previous unread count and retry on the next history refresh.
  }
}

function scheduleChannelRead(): void {
  const channelId = activeChannel.value?.id;
  if (!channelId || !pendingChannelRead || channelReadTimer || syncingChannelRead ||
      isLoadingMessages.value || !isVisibleChannel(channelId)) return;
  const current = captureChatOwner();
  channelReadTimer = setTimeout(async () => {
    channelReadTimer = undefined;
    if (!current() || !isVisibleChannel(channelId) || isLoadingMessages.value) return;
    const cursor = displayedChatCursor(messages.value.filter(message => message.id <= pendingChannelRead));
    pendingChannelRead = 0;
    if (!cursor) return;
    syncingChannelRead = true;
    try {
      await acknowledgeDisplayedChannel(channelId, cursor, current);
    } finally {
      syncingChannelRead = false;
      scheduleChannelRead();
    }
  }, 250);
}

function refreshVisibleChannel(): void {
  const channelId = activeChannel.value?.id;
  if (channelId && messagePage.value === 1 && isVisibleChannel(channelId)) {
    void app.runWithContext(() => loadMessages(channelId));
  }
}

async function loadMessages(
  channelId: number,
  reset = true
): Promise<void> {
  if (isLoadingMessages.value && !reset) return;
  const request = ++messageRequest;
  const ownsPage = captureChatOwner();
  const query = channelSearch.value;
  const current = () => ownsPage() && request === messageRequest &&
    activeChannel.value?.id === channelId && channelSearch.value === query;
  const changes = new Map<number, ChatMessageType | null>();
  liveChannelChanges = changes;
  isLoadingMessages.value = true;
  failedMessageLoad.value = null;
  try {
    const page = reset ? 1 : messagePage.value + 1;
    const result = await v2ListChatMessages(channelId, {
      page,
      page_size: 50,
      ...query,
    });
    if (!current()) return;
    const mapped = result.items.map(message =>
      mapV2ChatMessage(message, membersById.value)
    );
    const displayedIds = new Set(messages.value.map(message => message.id));
    let next = reset ? mapped : [
      ...mapped.filter(message => !displayedIds.has(message.id)),
      ...messages.value
    ];
    for (const [id, change] of changes) {
      next = change === null ? next.filter(message => message.id !== id) : replaceChatMessage(next, change);
    }
    messages.value = next;
    messagePage.value = page;
    hasMoreMessages.value = result.meta?.has_next ?? false;
    if (reset && !query) {
      const cursor = displayedChatCursor(next);
      if (cursor && isVisibleChannel(channelId)) {
        if (pendingChannelRead <= cursor) pendingChannelRead = 0;
        void acknowledgeDisplayedChannel(channelId, cursor, current);
      }
    }
  } catch {
    if (current()) failedMessageLoad.value = reset;
  } finally {
    if (liveChannelChanges === changes) liveChannelChanges = null;
    if (ownsPage() && request === messageRequest) {
      isLoadingMessages.value = false;
      scheduleChannelRead();
    }
  }
}

function retryChannelHistory(): void {
  const channelId = activeChannel.value?.id;
  const reset = failedMessageLoad.value;
  if (channelId === undefined || reset === null || isLoadingMessages.value) return;
  void app.runWithContext(() => loadMessages(channelId, reset));
}

async function loadDirectConversations(
  showLoading = true,
  page = requestedDirectListPage
): Promise<void> {
  const request = ++conversationListRequest;
  const ownsPage = captureChatOwner();
  const current = () => ownsPage() && request === conversationListRequest;
  requestedDirectListPage = page;
  if (showLoading) {
    isLoadingDirectConversations.value = true;
  }
  try {
    const readPage = (target: number) => app.runWithContext(() => v2ListDirectConversations({ page: target, page_size: 20 }));
    let result = await readPage(page);
    if (!current()) return;
    if (page > 1 && !result.items.length) {
      page = 1;
      result = await readPage(page);
      if (!current()) return;
    }
    if (result.meta?.page !== page) throw Error('UNEXPECTED_DIRECT_CONVERSATION_PAGE');
    directConversations.value = sortDirectConversations(
      result.items
    );
    directListPage.value = requestedDirectListPage = page;
    hasMoreDirectConversations.value = result.meta.has_next === true;
  } catch {
    if (current()) {
      requestedDirectListPage = directListPage.value;
      toast.error(t('chat.feedback.loadDirectConversationsFailed'));
    }
  } finally {
    if (current()) {
      isLoadingDirectConversations.value = false;
    }
  }
}

async function loadDirectMessagesForConversation(
  conversationId: number,
  clear = true,
  older = false,
  background = false
): Promise<void> {
  if (older && (loadingOlderDirectMessages.value || isLoadingDirectMessages.value || !hasOlderDirectMessages.value)) return;
  const request = ++conversationRequest;
  const ownsPage = captureChatOwner();
  const query = directSearch.value;
  const current = () => ownsPage() && request === conversationRequest &&
    directConversationId.value === conversationId && directSearch.value === query;
  const changes = new Map<number, V2DirectMessage | null>();
  liveDirectChanges = changes;
  const page = older ? directHistoryPage.value + 1 : 1;
  if (clear) directMessages.value = [];
  if (older) loadingOlderDirectMessages.value = true;
  else if (!background) {
    loadingOlderDirectMessages.value = false;
    isLoadingDirectMessages.value = true;
    if (clear) {
      directHistoryPage.value = 1;
      hasOlderDirectMessages.value = false;
    }
  }
  try {
    const result = await app.runWithContext(() => v2ListDirectMessages(conversationId, { page, page_size: 20, mark_read: false, ...query }));
    if (!current()) return;
    if (result.meta?.page !== page) throw Error('UNEXPECTED_DIRECT_HISTORY_PAGE');
    const pageIds = background ? new Set(result.items.map(message => message.message_id)) : null;
    const retained = pageIds ? directMessages.value.filter(message => !pageIds.has(message.message_id))
      : older ? directMessages.value : [];
    directMessages.value = reconcileDirectHistory(result.items, retained, changes);
    if (!background || directHistoryPage.value === 1) {
      directHistoryPage.value = page;
      hasOlderDirectMessages.value = result.meta.has_next === true;
    }
  } catch {
    if (current() && !background) toast.error(t('chat.feedback.loadDirectMessagesFailed'));
  } finally {
    if (liveDirectChanges === changes) liveDirectChanges = null;
    if (current()) {
      isLoadingDirectMessages.value = false;
      loadingOlderDirectMessages.value = false;
      scheduleDirectRead();
    }
  }
}

function applyDirectReadStatus(status: V2DirectReadStatus): void {
  if (status.conversation_id === directConversationId.value) {
    const prior = directReadStatus.value;
    if ((status.last_read_message_id ?? 0) < (prior?.last_read_message_id ?? 0) ||
        (status.participant_last_read_message_id ?? 0) < (prior?.participant_last_read_message_id ?? 0)) return;
    directReadStatus.value = status;
  }
  directConversations.value = directConversations.value.map(conversation =>
    conversation.conversation_id === status.conversation_id ? { ...conversation, unread_count: status.unread_count } : conversation);
}

async function refreshDirectReadStatus(conversationId: number): Promise<void> {
  const owner = captureChatOwner();
  const active = conversationId === directConversationId.value;
  const request = active ? ++directReadRequest : null;
  try {
    const status = await app.runWithContext(() => v2GetDirectReadStatus(conversationId));
    if (!owner() || request !== null && (conversationId !== directConversationId.value || request !== directReadRequest)) return;
    applyDirectReadStatus(status);
  } catch { /* The current state is refreshed on the next successful read or reconnect. */ }
}

function directIsVisible(): boolean {
  return typeof document !== 'undefined' && document.visibilityState === 'visible' &&
    directSearch.value === null &&
    (directSheetOpen.value || directMessageStandaloneTarget.value !== null) &&
    (!isMobileNavigationOpen.value || window.matchMedia('(min-width: 768px)').matches);
}

function markVisibleDirectMessage(id: number): void {
  pendingDirectRead = Math.max(id, pendingDirectRead);
  scheduleDirectRead();
}

function scheduleDirectRead(): void {
  const conversationId = directConversationId.value;
  if (!conversationId || pendingDirectRead <= (directReadStatus.value?.last_read_message_id ?? 0) ||
      directReadTimer || activeDirectReadWrite !== null || !directIsVisible()) return;
  const owner = captureChatOwner();
  const selection = directSelectionRevision;
  const current = () => owner() && selection === directSelectionRevision && conversationId === directConversationId.value;
  directReadTimer = setTimeout(async () => {
    directReadTimer = undefined;
    if (!current() || !directIsVisible()) return;
    const cursor = pendingDirectRead;
    pendingDirectRead = 0;
    if (cursor <= (directReadStatus.value?.last_read_message_id ?? 0) ||
        !directMessages.value.some(message => message.message_id === cursor)) return;
    const request = ++directReadRequest;
    activeDirectReadWrite = request;
    try {
      const status = await app.runWithContext(() => v2SetDirectReadStatus(conversationId, cursor));
      if (current()) applyDirectReadStatus(status);
    } catch { /* A future visible cursor or reconnect can refresh the read position. */ }
    finally {
      if (activeDirectReadWrite === request) activeDirectReadWrite = null;
      if (current()) scheduleDirectRead();
    }
  }, 250);
}

function loadOlderDirectMessages(): void {
  const conversationId = directConversationId.value;
  if (conversationId !== null) void loadDirectMessagesForConversation(conversationId, false, true);
}

async function openDirectConversation(
  conversation: V2DirectConversation
): Promise<void> {
  exitDirectMessageView();
  upsertDirectConversation(conversation);
  directConversationId.value = conversation.conversation_id;
  directMessageTargetId.value = conversation.participant.user_id;
  directMessageStandaloneTarget.value =
    mapV2DirectConversationMember(conversation);
  showMobileContent();
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
  if (!('dm' in route.query) && !('conversation' in route.query)) return;
  const query = { ...route.query };
  delete query.dm;
  delete query.conversation;
  void router.replace({
    path: route.path,
    query
  });
}

function cancelDirectLinkLookup(): void {
  directLinkRequest++;
  directLinkStatus.value = null;
  clearDirectMessageQuery();
}

function retryDirectLinkLookup(): void {
  void app.runWithContext(openDirectMessageFromQuery);
}

async function openDirectMessageFromQuery(): Promise<void> {
  const current = captureChatOwner();
  const selection = directSelectionRevision;
  const rawConversation = route.query.conversation;
  if (rawConversation !== undefined) {
    const conversationId = notificationTargetId(rawConversation);
    if (conversationId === null) {
      cancelDirectLinkLookup();
      toast.error(t('chat.feedback.openDirectConversationFailed'));
      return;
    }
    const request = ++directLinkRequest;
    const stillCurrent = () => current() && selection === directSelectionRevision &&
      request === directLinkRequest && route.query.conversation === rawConversation;
    directLinkStatus.value = 'loading';
    showMobileNavigation();
    try {
      const result = await v2ListDirectConversations({ conversation_id: conversationId, page: 1, page_size: 1 });
      if (!stillCurrent()) return;
      const conversation = result.items.length === 1 ? result.items[0] : undefined;
      if (conversation?.conversation_id !== conversationId) {
        directLinkStatus.value = 'failed';
        return;
      }
      clearDirectMessageQuery();
      await openDirectConversation(conversation);
    } catch {
      if (stillCurrent()) directLinkStatus.value = 'failed';
    }
    return;
  }
  directLinkRequest++;
  directLinkStatus.value = null;
  const targetUserId = directMessageQueryUserId();
  if (!targetUserId) return;
  const originalTarget = route.query.dm;
  const sameQuery = () => current() && route.query.dm === originalTarget && route.query.conversation === undefined;
  if (targetUserId === currentUserId.value) {
    toast.error(t('chat.feedback.cannotMessageSelf'));
    clearDirectMessageQuery();
    return;
  }

  try {
    const conversation = await v2CreateDirectConversation({
      target_user_id: targetUserId
    });
    if (!sameQuery() || selection !== directSelectionRevision) return;
    await openDirectConversation(conversation);
    if (sameQuery()) await loadDirectConversations(false);
  } catch {
    if (sameQuery() && selection === directSelectionRevision) toast.error(t('chat.feedback.loadDirectMessagesFailed'));
  } finally {
    if (sameQuery()) clearDirectMessageQuery();
  }
}

async function refreshChannels(
  preferredChannelId?: number
): Promise<void> {
  if (!activeGroup.value) return;
  const groupId = activeGroup.value.id;
  const current = captureChatOwner();
  const request = ++channelsRequest;
  const observedMuteRevision = muteRevision;
  const channels = await v2ListChatChannels(groupId);
  if (!current() || activeGroup.value?.id !== groupId || request !== channelsRequest) return;
  channelCategories.value = buildChatChannelCategories(channels);
  for (const channel of allChannels()) {
    const confirmed = confirmedMutes.get(channel.id);
    if (confirmed && confirmed.revision > observedMuteRevision) channel.isMuted = confirmed.muted;
  }

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
  const request = ++groupRequest;
  const owner = captureChatOwner();
  if (activeGroup.value?.id !== group.id) {
    activeChannel.value = null;
    channelCategories.value = [];
    messages.value = [];
    members.value = [];
    channelSearch.value = null;
  }
  activeGroup.value = group;
  const current = () => owner() && groupRequest === request && activeGroup.value?.id === group.id;
  writeLastChatGroupId(group.id);
  loadingGroupChannels.value = true;
  channelLoadFailed.value = false;
  void v2ListChatMembers(group.id).then(items => {
    if (current()) members.value = items.map(mapV2ChatMember);
  }).catch(() => {
    if (current()) members.value = [];
  });
  try {
    await refreshChannels();
  } catch {
    if (current()) channelLoadFailed.value = true;
    return null;
  } finally {
    if (current()) loadingGroupChannels.value = false;
  }
  if (!current()) return null;

  if (activeChannel.value) {
    const channelId = activeChannel.value.id;
    await app.runWithContext(() => loadMessages(channelId));
  }
  return current() ? activeChannel.value : null;
}

function retryGroupChannels(): void {
  if (activeGroup.value && !loadingGroupChannels.value) void loadGroup(activeGroup.value);
}

async function loadChat(): Promise<void> {
  const current = captureChatOwner();
  const request = ++chatRequest;
  const valid = () => current() && request === chatRequest;
  isLoading.value = true;
  loadingMoreGroups.value = false;
  errorMessage.value = '';
  try {
    const [result] = await Promise.all([
      v2ListChatGroups({
        page: 1,
        page_size: 20
      }),
      loadDirectConversations()
    ]);
    if (!valid()) return;
    groups.value = result.items.map(mapV2ChatGroup);
    groupPage.value = 1;
    hasMoreGroups.value = result.meta?.page === 1 && result.meta.has_next === true;
    const nextGroup = preferredChatGroup();
    if (nextGroup) {
      await app.runWithContext(() => loadGroup(nextGroup));
    }
  } catch {
    if (valid()) errorMessage.value = t('chat.feedback.loadFailed');
  } finally {
    if (valid()) isLoading.value = false;
  }
}

async function loadMoreGroups(): Promise<void> {
  if (isLoading.value || loadingMoreGroups.value || !hasMoreGroups.value) return;
  const ownsPage = captureChatOwner();
  const request = chatRequest;
  const current = () => ownsPage() && request === chatRequest;
  const page = groupPage.value + 1;
  loadingMoreGroups.value = true;
  try {
    const result = await v2ListChatGroups({ page, page_size: 20 });
    if (!current()) return;
    if (result.meta?.page !== page) throw Error('UNEXPECTED_CHAT_GROUP_PAGE');
    const unique = new Map(groups.value.map(group => [group.id, group]));
    for (const row of result.items) unique.set(row.group_id, mapV2ChatGroup(row));
    groups.value = [...unique.values()];
    groupPage.value = page;
    hasMoreGroups.value = result.meta.has_next === true;
  } catch {
    if (current()) toast.error(t('chat.feedback.loadFailed'));
  } finally {
    if (current()) loadingMoreGroups.value = false;
  }
}

async function handleSelectChannel(
  channel: Channel
): Promise<void> {
  exitDirectMessageView();
  showMobileContent();
  if (activeChannel.value?.id === channel.id) {
    refreshVisibleChannel();
    return;
  }
  activeChannel.value = channel;
  channelSearch.value = null;
  await loadMessages(channel.id);
}

async function handleSelectGroup(groupId: number): Promise<void> {
  const group = groups.value.find(item => item.id === groupId);
  if (!group) return;

  exitDirectMessageView();

  if (group.id === activeGroup.value?.id && !channelLoadFailed.value) return;
  await loadGroup(group);
}

async function uploadAttachments(
  files: File[],
  authRevision: number,
  signal: AbortSignal,
  current: () => boolean
): Promise<number[] | null> {
  const mediaIds: number[] = [];
  for (const file of files) {
    if (!current()) return null;
    const uploaded = uploadedChannelAttachments.get(file);
    let id = uploaded?.authRevision === authRevision ? uploaded.id : undefined;
    if (id === undefined) {
      const form = new FormData();
      form.append('file', file);
      form.append('alt_text', file.name);
      form.append('access_scope', 'chat');
      const media = await app.runWithContext(() => v2UploadMedia(form, signal));
      if (!current()) return null;
      if (!media || media.thumbnail_url !== null || !isPrivateMediaContent(media.media_id, media.public_url)) {
        throw new Error('INVALID_CHAT_ATTACHMENT_RECEIPT');
      }
      id = media.media_id;
    }
    if (mediaIds.includes(id)) throw new Error('DUPLICATE_CHAT_ATTACHMENT');
    uploadedChannelAttachments.set(file, { id, authRevision });
    mediaIds.push(id);
  }
  return mediaIds;
}

async function handleSendMessage(
  content: string,
  attachments: File[] = [],
  replyToMessageId?: number
): Promise<boolean> {
  if (
    !activeChannel.value ||
    channelSearch.value !== null ||
    isSending.value ||
    !canSendActiveChannel.value
  ) {
    return false;
  }
  channelTyping.stop();
  const channelId = activeChannel.value.id;
  const actorId = currentUserId.value;
  const revision = channelComposerRevision.value;
  const authRevision = preferenceStore.authRevision();
  const ownsPage = captureChatOwner();
  const current = () => ownsPage() && channelComposerRevision.value === revision;
  const upload = new AbortController();
  channelAttachmentUpload = upload;
  isSending.value = true;
  try {
    const mediaIds = await uploadAttachments(attachments, authRevision, upload.signal, current);
    if (channelAttachmentUpload === upload) channelAttachmentUpload = null;
    if (!mediaIds || !current()) return false;
    const created = await app.runWithContext(() => v2CreateChatMessage(
      channelId,
      {
        content,
        media_ids: mediaIds,
        reply_to_message_id: replyToMessageId ?? null
      }
    ));
    if (!current()) return false;
    if (!created || created.channel_id !== channelId || created.author?.user_id !== actorId ||
        !Number.isSafeInteger(created.message_id) || created.message_id <= 0 ||
        !Array.isArray(created.media) || created.media.length !== mediaIds.length ||
        mediaIds.some(id => !created.media.some(media =>
          media.media_id === id && isPrivateMediaContent(id, media.public_url)))) {
      throw new Error('INVALID_CHAT_SEND_RECEIPT');
    }
    if (!channelSearch.value) upsertMessage(mapV2ChatMessage(created, membersById.value));
    updateChannelPreview(created, true);
    for (const file of attachments) uploadedChannelAttachments.delete(file);
    toast.success(t('chat.feedback.sent'));
    return true;
  } catch {
    if (current()) toast.error(t('chat.feedback.sendFailed'));
    return false;
  } finally {
    if (channelAttachmentUpload === upload) channelAttachmentUpload = null;
    if (channelComposerRevision.value === revision) isSending.value = false;
  }
}

async function handleReact(
  messageId: number,
  emoji: string
): Promise<void> {
  const scope = captureChannelMessageWrite();
  const message = messages.value.find(item => item.id === messageId);
  if (!scope.current() || !message || pendingChannelReactions.has(messageId)) return;
  const reacted = message.reactions?.some(
    reaction => reaction.emoji === emoji && reaction.reacted
  );
  pendingChannelReactions.add(messageId);
  try {
    const updated = reacted
      ? await v2DeleteChatReaction(messageId, { emoji })
      : await v2CreateChatReaction(messageId, { emoji });
    if (!scope.current()) return;
    if (!scope.confirms(updated)) throw new Error('Unexpected chat reaction scope');
    const visible = messages.value.find(item => item.id === messageId);
    if (visible) {
      const reactions = mapV2ChatMessage(updated, membersById.value).reactions;
      upsertMessage({ ...visible, reactions });
    }
  } catch {
    if (scope.current()) toast.error(t('chat.feedback.reactionFailed'));
  } finally {
    if (scope.current()) pendingChannelReactions.delete(messageId);
  }
}

async function handleDeleteMessage(
  messageId: number
): Promise<void> {
  const scope = captureChannelMessageWrite();
  if (!scope.current() || !messages.value.some(message => message.id === messageId)) return;
  try {
    await v2DeleteChatMessage(messageId);
    if (!scope.current()) return;
    removeChannelMessage(messageId);
    toast.success(t('chat.feedback.deleted'));
    void refreshChannels().catch(() => undefined);
  } catch {
    if (scope.current()) toast.error(t('chat.feedback.deleteFailed'));
  }
}

function captureChannelMessageWrite() {
  const owner = captureChatOwner();
  const revision = channelComposerRevision.value;
  const groupId = activeGroup.value?.id;
  const channelId = activeChannel.value?.id;
  const current = () => owner() && channelId !== undefined && groupId !== undefined &&
    revision === channelComposerRevision.value && activeGroup.value?.id === groupId &&
    activeChannel.value?.id === channelId;
  const confirms = (message: V2ChatMessage) => message.channel_id === channelId && message.group_id === groupId;
  return { current, confirms };
}

async function handleEditMessage(
  message: ChatMessageType
): Promise<void> {
  const scope = captureChannelMessageWrite();
  if (!import.meta.client || !scope.current() || message.author.id !== currentUserId.value ||
      message.type !== 'text') return;
  const content = window
    .prompt(t('chat.prompts.messageContent'), message.content)
    ?.trim();
  if (!content || content === message.content) return;

  try {
    const updated = await v2UpdateChatMessage(message.id, {
      content
    });
    if (!scope.current()) return;
    if (!scope.confirms(updated)) throw new Error('Unexpected chat message scope');
    const visible = messages.value.find(item => item.id === message.id);
    if (!visible) return;
    const result = mapV2ChatMessage(updated, membersById.value);
    upsertMessage({ ...visible, content: result.content, editedAt: result.editedAt });
    toast.success(t('chat.feedback.messageUpdated'));
  } catch {
    if (scope.current()) toast.error(t('chat.feedback.updateMessageFailed'));
  }
}

async function handlePinMessage(messageId: number): Promise<void> {
  const scope = captureChannelMessageWrite();
  const message = messages.value.find(
    message => message.id === messageId
  );
  if (!scope.current() || !message?.canPin) return;

  try {
    const updated = await v2SetChatMessagePinStatus(messageId, {
      is_pinned: !message.isPinned
    });
    if (!scope.current()) return;
    if (!scope.confirms(updated)) throw new Error('Unexpected chat message scope');
    const visible = messages.value.find(item => item.id === messageId);
    if (!visible) return;
    upsertMessage({ ...visible, isPinned: updated.is_pinned });
    toast.success(
      updated.is_pinned
        ? t('chat.feedback.pinned')
        : t('chat.feedback.unpinned')
    );
  } catch {
    if (scope.current()) toast.error(t('chat.feedback.pinFailed'));
  }
}

function handleCreateChannel(categoryId: number | null): void {
  if (!canManage.value || channelWriteBusy.value) return;
  editingChannelId.value = null;
  createChannelName.value = '';
  channelCategory.value = categoryId === null ? '' : findCategoryName(categoryId);
  channelPrivate.value = false;
  createChannelDialogOpen.value = true;
}

function captureChannelWrite(): () => boolean {
  const owner = captureChatOwner();
  const revision = channelWriteRevision;
  return () => owner() && revision === channelWriteRevision;
}

async function submitChannel(): Promise<void> {
  const group = activeGroup.value;
  const target = editingChannelId.value;
  if (!group?.canManage || !canSubmitCreateChannel.value) return;
  if (target !== null && !allChannels().some(channel => channel.id === target)) return;
  const current = captureChannelWrite();
  const payload = {
    name: createChannelName.value.trim(),
    category: channelCategory.value.trim(),
    is_private: channelPrivate.value
  };

  channelWriteBusy.value = true;
  let confirmed = false;
  try {
    const result = target === null
      ? await v2CreateChatChannel(group.id, { ...payload, type: 'text' })
      : await v2UpdateChatChannel(target, payload);
    if (!current()) return;
    if (result.group_id !== group.id) throw new Error('Unexpected chat channel group');
    confirmed = true;
    createChannelDialogOpen.value = false;
    toast.success(t(target === null ? 'chat.feedback.channelCreated' : 'chat.feedback.channelUpdated'));
    const previousChannel = activeChannel.value?.id;
    await refreshChannels(target === null ? result.channel_id : undefined);
    if (!current()) return;
    if (activeChannel.value && activeChannel.value.id !== previousChannel) {
      await loadMessages(activeChannel.value.id);
    }
  } catch {
    if (current()) toast.error(t(confirmed ? 'chat.feedback.loadFailed' :
      target === null ? 'chat.feedback.createChannelFailed' : 'chat.feedback.updateChannelFailed'));
  } finally {
    if (current()) channelWriteBusy.value = false;
  }
}

function handleEditChannel(channel: Channel): void {
  if (!canManage.value || channelWriteBusy.value) return;
  const category = channelCategories.value.find(item => item.channels.some(item => item.id === channel.id));
  if (!category) return;
  editingChannelId.value = channel.id;
  createChannelName.value = channel.name;
  channelCategory.value = category.name;
  channelPrivate.value = channel.isPrivate === true;
  createChannelDialogOpen.value = true;
}

async function handleDeleteChannel(
  channelId: number
): Promise<void> {
  if (!import.meta.client || !canManage.value || channelWriteBusy.value ||
      !allChannels().some(channel => channel.id === channelId)) return;
  if (!window.confirm(t('chat.prompts.deleteChannel'))) return;

  const current = captureChannelWrite();
  channelWriteBusy.value = true;
  let confirmed = false;
  try {
    await v2DeleteChatChannel(channelId);
    if (!current()) return;
    confirmed = true;
    for (const category of channelCategories.value) {
      category.channels = category.channels.filter(channel => channel.id !== channelId);
    }
    toast.success(t('chat.feedback.channelDeleted'));
    const deletedActive = activeChannel.value?.id === channelId;
    if (deletedActive) {
      messages.value = [];
      activeChannel.value = null;
    }
    await refreshChannels();
    if (!current()) return;
    if (deletedActive && activeChannel.value) {
      await loadMessages(activeChannel.value.id);
    }
  } catch {
    if (current()) toast.error(t(confirmed ? 'chat.feedback.loadFailed' : 'chat.feedback.deleteChannelFailed'));
  } finally {
    if (current()) channelWriteBusy.value = false;
  }
}

async function handleToggleChannelMute(
  channelId?: number
): Promise<void> {
  const targetId = channelId ?? activeChannel.value?.id;
  if (!targetId || muteRequests.has(targetId)) return;
  const channel = allChannels().find(item => item.id === targetId);
  if (!channel) return;
  const ownsPage = captureChatOwner();
  const request = new AbortController();
  const current = () => ownsPage() && muteRequests.get(targetId) === request;
  muteRequests.set(targetId, request);
  try {
    const { is_muted: muted } = await v2SetChatChannelMuteStatus(targetId, !channel.isMuted, request.signal);
    if (!current()) return;
    confirmedMutes.set(targetId, { muted, revision: ++muteRevision });
    const listedChannel = allChannels().find(item => item.id === targetId);
    if (listedChannel) listedChannel.isMuted = muted;
    if (activeChannel.value?.id === targetId) {
      activeChannel.value.isMuted = muted;
    }
    toast.success(
      muted
        ? t('chat.feedback.channelMuted')
        : t('chat.feedback.channelUnmuted')
    );
  } catch {
    if (current()) toast.error(t('chat.feedback.muteFailed'));
  } finally {
    if (muteRequests.get(targetId) === request) muteRequests.delete(targetId);
  }
}

function clearMuteRequests(): void {
  for (const request of muteRequests.values()) request.abort();
  muteRequests.clear();
  confirmedMutes.clear();
}

function handleSearch(filters: ChatMessageFilters | null): void {
  if (!filters && !channelSearch.value) return;
  channelSearch.value = filters;
  if (filters) channelTyping.stop();
  const channelId = activeChannel.value?.id;
  if (channelId !== undefined) void loadMessages(channelId);
}

function handleDirectSearch(filters: ChatMessageFilters | null): void {
  if (!filters && !directSearch.value) return;
  directSearch.value = filters;
  clearTimeout(directReadTimer);
  directReadTimer = undefined;
  pendingDirectRead = 0;
  if (filters) directTyping.stop();
  const id = directConversationId.value;
  if (id !== null) void loadDirectMessagesForConversation(id);
}

function toggleStandaloneDirectSearch(): void {
  standaloneDirectSearchOpen.value = !standaloneDirectSearchOpen.value;
  if (!standaloneDirectSearchOpen.value) handleDirectSearch(null);
}

function clearInviteSearch(): void {
  if (inviteSearchTimer) clearTimeout(inviteSearchTimer);
  inviteSearchTimer = null;
  inviteSearchRequest?.abort();
  inviteSearchRequest = undefined;
  isSearchingInviteUsers.value = false;
  inviteUsers.value = [];
}

function resetInviteDialog(): void {
  clearInviteSearch();
  inviteSubmitRequest?.abort();
  inviteSubmitRequest = undefined;
  isCreatingInvite.value = false;
  inviteResultUnknown.value = false;
  selectedInvitee.value = null;
  createdInvite.value = null;
  inviteSearchQuery.value = '';
  inviteMessage.value = '';
}

function handleInviteSearchInput(): void {
  clearInviteSearch();
  selectedInvitee.value = null;
  createdInvite.value = null;
  const query = inviteSearchQuery.value.trim();
  if (!inviteDialogOpen.value || query.length < 2) return;
  isSearchingInviteUsers.value = true;
  inviteSearchTimer = setTimeout(() => {
    inviteSearchTimer = null;
    void searchInviteUsers(query);
  }, 300);
}

async function searchInviteUsers(query: string): Promise<void> {
  const request = new AbortController();
  inviteSearchRequest = request;
  const ownsPage = captureChatOwner();
  const current = () => ownsPage() && inviteDialogOpen.value && inviteSearchRequest === request;
  try {
    const result = await app.runWithContext(() => v2SearchUsers({
      q: query,
      page: 1,
      pageSize: 12,
      sort: 'popular'
    }, request.signal));
    if (current()) inviteUsers.value = result.items;
  } catch (error) {
    if (!current()) return;
    toast.error(t('chat.feedback.searchUsersFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    if (current()) isSearchingInviteUsers.value = false;
  }
}

function selectInvitee(user: PublicUserVM): void {
  if (isCreatingInvite.value || inviteResultUnknown.value ||
      !inviteCandidates.value.some(candidate => candidate.id === user.id)) return;
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
  const invitee = pendingInvitee.value;
  if (!group || !inviteDialogOpen.value || isCreatingInvite.value || inviteResultUnknown.value ||
      invitee === undefined || isSearchingInviteUsers.value) return;
  const message = inviteMessage.value.trim();
  if (new TextEncoder().encode(message).length > 200) {
    toast.error(t('chat.invite.messageTooLong'));
    return;
  }

  const request = new AbortController();
  const ownsPage = captureChatOwner();
  inviteSubmitRequest = request;
  const current = () => ownsPage() && inviteDialogOpen.value && inviteSubmitRequest === request;
  isCreatingInvite.value = true;
  createdInvite.value = null;
  try {
    inviteMaxUses.value = normalizedPositiveInteger(
      inviteMaxUses.value,
      25
    );
    inviteExpireHours.value = normalizedPositiveInteger(
      inviteExpireHours.value,
      168
    );
    const invite = await app.runWithContext(() => v2CreateGroupInvite(group.id, {
      invitee_id: invitee,
      max_uses: invitee === null ? inviteMaxUses.value : 1,
      expire_hours: inviteExpireHours.value,
      message: message || undefined
    }, request.signal));
    if (!current()) return;
    if (!Number.isSafeInteger(invite?.invite_id) || invite.invite_id <= 0 ||
        (invitee === null ? !inviteUrl(invite) : invite.invite_code !== null || invite.invite_url !== null)) {
      throw new Error('Invalid invite receipt');
    }
    createdInvite.value = invite;

    const url = inviteUrl(invite);
    if (url) {
      await copyText(url).catch(() => undefined);
    }
    if (!current()) return;
    toast.success(
      invitee !== null
        ? t('chat.feedback.memberInvited')
        : t('chat.feedback.inviteCreated')
    );
  } catch (error) {
    if (!current()) return;
    const failure = error as {statusCode?: number; status?: number} | null;
    if ([400, 401, 403, 404, 422, 429].includes(failure?.statusCode ?? failure?.status ?? 0)) {
      toast.error(t('chat.feedback.inviteFailed'));
    } else {
      inviteResultUnknown.value = true;
    }
  } finally {
    if (current()) isCreatingInvite.value = false;
  }
}

function handleLoadMore(): void {
  if (!activeChannel.value || !hasMoreMessages.value || failedMessageLoad.value !== null) return;
  void loadMessages(activeChannel.value.id, false);
}

function openMemberProfile(userId: number): void {
  if (!Number.isFinite(userId) || userId <= 0) return;
  void navigateTo(localePath(`/user/${userId}/profile`));
}

async function startChatCall(member: ChatMember, mode: CallMode): Promise<void> {
  if (member.id === currentUserId.value) return;
  const current = captureChatOwner();
  try {
    const existing = member.id === directMessageTargetId.value ? directConversationId.value : null;
    const id = existing ?? (await app.runWithContext(() => v2CreateDirectConversation({target_user_id:member.id}))).conversation_id;
    if (current()) await calls.start(id,member.id,member.nickname || member.username,mode);
  } catch {
    if (current()) toast.error(t('chat.calls.problem.unavailable'));
  }
}

async function handleOpenDirectMessage(
  member: ChatMember,
  standalone = false
): Promise<void> {
  const owner = captureChatOwner();
  exitDirectMessageView();
  const selection = directSelectionRevision;
  const current = () => owner() && selection === directSelectionRevision;
  directMessageTargetId.value = member.id;
  if (standalone) {
    directMessageStandaloneTarget.value = member;
    showMobileContent();
  }
  isLoadingDirectMessages.value = true;

  try {
    const conversation = await v2CreateDirectConversation({
      target_user_id: member.id
    });
    if (!current()) return;
    directConversationId.value = conversation.conversation_id;
    upsertDirectConversation(conversation);
    await loadDirectMessagesForConversation(
      conversation.conversation_id
    );
  } catch {
    if (current()) toast.error(t('chat.feedback.loadDirectMessagesFailed'));
  } finally {
    if (current()) isLoadingDirectMessages.value = false;
  }
}

async function handleOpenDirectMessageStandalone(
  member: ChatMember
): Promise<void> {
  if (directMessageTargetId.value === member.id && directConversationId.value) {
    directMessageStandaloneTarget.value = member;
    directSheetOpen.value = false;
    handleDirectSearch(null);
    showMobileContent();
    return;
  }
  await handleOpenDirectMessage(member, true);
}

function onDirectSheetVisibility(open: boolean): void {
  directSheetOpen.value = open;
  if (!open && !directMessageStandaloneTarget.value) exitDirectMessageView();
  if (open) channelTyping.stop();
}

async function handleSelectDirectConversation(
  conversation: V2DirectConversation
): Promise<void> {
  if (directLinkStatus.value) cancelDirectLinkLookup();
  await openDirectConversation(conversation);
}

function closeDirectMessageStandalone(): void {
  exitDirectMessageView();
  showMobileNavigation();
}

function exitDirectMessageView(): void {
  directSelectionRevision++;
  directLinkRequest++;
  directLinkStatus.value = null;
  conversationRequest++;
  isSendingDirectMessage.value = false;
  directAttachmentUpload?.abort();
  directAttachmentUpload = null;
  pendingDirectReactions.clear();
  for (const request of directMessageRefreshes.values()) request.abort();
  directMessageRefreshes.clear();
  closeDirectDelete();
  liveDirectChanges = null;
  directMessageStandaloneTarget.value = null;
  directSearch.value = null;
  standaloneDirectSearchOpen.value = false;
  standaloneDirectReplyId.value = null;
  directConversationId.value = null;
  directMessageTargetId.value = null;
  directMessages.value = [];
  directHistoryPage.value = 1;
  hasOlderDirectMessages.value = loadingOlderDirectMessages.value = isLoadingDirectMessages.value = false;
}

async function submitStandaloneDirectMessage(content: string, attachments?: File[]): Promise<boolean> {
  const target = directMessageStandaloneTarget.value;
  if (!target) return false;
  const selection = directSelectionRevision;
  const replyId = standaloneDirectReply.value?.id;
  const sent = await handleSendDirectMessage(target.id, content, attachments, replyId);
  if (sent && selection === directSelectionRevision && standaloneDirectReplyId.value === replyId) {
    standaloneDirectReplyId.value = null;
  }
  return sent;
}

async function handleSendDirectMessage(
  targetUserId: number,
  content: string,
  attachments: File[] = [],
  replyToMessageId?: number,
): Promise<boolean> {
  if (isSendingDirectMessage.value || isLoadingDirectMessages.value || directSearch.value ||
      directMessageTargetId.value !== targetUserId) return false;
  directTyping.stop();
  const owner = captureChatOwner();
  const selection = directSelectionRevision;
  const authRevision = preferenceStore.authRevision();
  const actorId = currentUserId.value;
  const current = () => owner() && selection === directSelectionRevision &&
    directMessageTargetId.value === targetUserId;
  if (!current()) return false;
  isSendingDirectMessage.value = true;
  const upload = new AbortController();
  directAttachmentUpload = upload;

  try {
    let conversationId = directConversationId.value;
    if (!conversationId) {
      const conversation = await v2CreateDirectConversation({
        target_user_id: targetUserId
      });
      if (!current()) return false;
      conversationId = conversation.conversation_id;
      directConversationId.value = conversationId;
      upsertDirectConversation(conversation);
    }

    const mediaIds = await uploadAttachments(attachments, authRevision, upload.signal, current);
    if (!mediaIds || !current()) return false;
    const created = await v2CreateDirectMessage(conversationId, {
      content,
      media_ids: mediaIds,
      reply_to_message_id: replyToMessageId ?? null,
    }, upload.signal);
    if (!current()) return false;
    if (created.author.user_id !== actorId) throw new Error('INVALID_DIRECT_MESSAGE_AUTHOR');
    for (const file of attachments) uploadedChannelAttachments.delete(file);
    const isActive = directConversationId.value === conversationId;
    if (isActive && !directSearch.value) upsertDirectMessage(created);
    updateDirectConversationPreview(created, isActive);
    void loadDirectConversations(false);
    toast.success(t('chat.feedback.directMessageSent'));
    return true;
  } catch {
    if (current()) toast.error(t('chat.feedback.directMessageFailed'));
    return false;
  } finally {
    if (directAttachmentUpload === upload) directAttachmentUpload = null;
    if (current()) isSendingDirectMessage.value = false;
  }
}

onMounted(() => {
  unsubscribeRealtime = realtime.subscribe(handleWsMessage);
  document.addEventListener('visibilitychange', refreshVisibleChannel);
  document.addEventListener('visibilitychange', scheduleChannelRead);
  document.addEventListener('visibilitychange', scheduleDirectRead);
  void loadChat();
});

watch(directConversationId, () => {
  closeDirectDelete();
  clearTimeout(directReadTimer);
  directReadTimer = undefined;
  pendingDirectRead = 0;
  activeDirectReadWrite = null;
  directReadRequest++;
  directReadStatus.value = null;
}, {flush:'sync'});
watch(directConversationId, id => { if (id !== null) void refreshDirectReadStatus(id); });
watch(isMobileNavigationOpen, scheduleDirectRead);
watch(isMobileNavigationOpen, open => {
  if (open) { directTyping.stop(); channelTyping.stop(); }
});
watch([isMobileNavigationOpen, directConversationId, directMessageStandaloneTarget], scheduleChannelRead);
watch([() => activeChannel.value?.id, channelSearch, realtime.ownerRevision], () => {
  messageRequest++;
  liveChannelChanges = null;
  isLoadingMessages.value = false;
  failedMessageLoad.value = null;
  messages.value = [];
  messagePage.value = 1;
  hasMoreMessages.value = false;
}, { flush: 'sync' });

watch([() => activeChannel.value?.id, realtime.ownerRevision, channelSearch], () => {
  clearTimeout(channelReadTimer);
  channelReadTimer = undefined;
  pendingChannelRead = 0;
  channelReadReceipt++;
}, { flush: 'sync' });

watch([
  () => activeChannel.value?.id,
  isDirectMessageStandalone,
  realtime.ownerRevision,
  currentUserId,
  () => preferenceStore.preferences.authSession?.sessionId
], () => {
  channelComposerRevision.value++;
  pendingChannelReactions.clear();
  channelAttachmentUpload?.abort();
  channelAttachmentUpload = null;
  uploadedChannelAttachments = new WeakMap();
  isSending.value = false;
}, { flush: 'sync' });

watch(
  [realtime.serverReady, () => activeChannel.value?.id ?? null],
  ([ready, channelId]) => syncChatChannel(ready, channelId),
  {flush: 'sync'}
);

watch(realtime.ownerRevision, () => {
  directTyping.reset(false);
  channelTyping.reset(false);
  clearMuteRequests();
  activeGroup.value = null;
  loadingGroupChannels.value = false;
  channelLoadFailed.value = false;
  activeChannel.value = null;
  channelCategories.value = [];
  groups.value = [];
  groupPage.value = 1;
  hasMoreGroups.value = loadingMoreGroups.value = false;
  members.value = [];
  messages.value = [];
  directConversations.value = [];
  directListPage.value = requestedDirectListPage = 1;
  hasMoreDirectConversations.value = false;
  exitDirectMessageView();
  isLoadingMessages.value = false;
  isLoadingDirectConversations.value = false;
  isLoadingDirectMessages.value = false;
  isSending.value = false;
  isSendingDirectMessage.value = false;
  messagePage.value = 1;
  hasMoreMessages.value = false;
  channelSearch.value = null;
  inviteDialogOpen.value = false;
  groupSettingsOpen.value = false;
  groupSettingsModel.value = null;
}, {flush: 'sync'});

watch(inviteSearchQuery, handleInviteSearchInput, {flush: 'sync'});
watch(inviteDialogOpen, open => { if (!open) resetInviteDialog(); }, {flush: 'sync'});
watch(() => activeGroup.value?.id, () => { inviteDialogOpen.value = false; }, {flush: 'sync'});
watch([() => activeGroup.value?.id, realtime.ownerRevision], () => {
  channelWriteRevision++;
  channelWriteBusy.value = false;
  createChannelDialogOpen.value = false;
}, {flush: 'sync'});

watch(realtime.ownerRevision, () => {
  if (preferenceStore.isLoggedIn) void app.runWithContext(loadChat);
}, {flush: 'post'});

watch(realtime.recoveryRevision, () => {
  void app.runWithContext(() => {
    void loadDirectConversations(false);
    if (activeChannel.value) void loadMessages(activeChannel.value.id);
    const id = directConversationId.value;
    if (id !== null) {
      void loadDirectMessagesForConversation(id, false, false, true);
      void refreshDirectReadStatus(id);
    }
  });
});

watch(
  [() => route.query.dm, () => route.query.conversation, isLoading],
  () => {
    if (!isLoading.value) {
      void app.runWithContext(openDirectMessageFromQuery);
    }
  }
);

watch([commandSearch, activeChannel, directConversationId, isLoading, realtime.ownerRevision], () => {
  const request = commandSearch.value;
  if (!request) return;
  if (request.owner !== commandAuth.revision || commandAuth.isIdentityChanging) {
    commandSearch.value = null;
    return;
  }
  if (isLoading.value || (directConversationId.value === null && !activeChannel.value)) return;
  commandSearch.value = null;
  if (directConversationId.value !== null) {
    standaloneDirectSearchOpen.value = true;
    handleDirectSearch({ q: request.query });
  } else {
    handleSearch({ q: request.query });
  }
}, { immediate: true, flush: 'post' });

const navTab = ref<'direct' | 'groups'>('direct');

watch(
  [isDirectMessageStandalone, () => activeChannel.value?.id ?? null],
  ([dmOpen, channelId]) => {
    if (dmOpen) {
      navTab.value = 'direct';
    } else if (channelId !== null && !dmOpen) {
      navTab.value = 'groups';
    }
  }
);

function dmDayKey(value: string): string {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return '';
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

function shouldShowDmDatePill(index: number): boolean {
  const list = directMessages.value ?? [];
  const msg = list[index];
  if (!msg) return false;
  if (index === 0) return true;
  const prev = list[index - 1];
  return !prev || dmDayKey(msg.created_at) !== dmDayKey(prev.created_at);
}

function formatDmDatePill(value: string): string {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return '';
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const target = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diffDays = Math.round((today - target) / 86400000);
  if (diffDays === 0) return t('chat.dateToday');
  if (diffDays === 1) return t('chat.dateYesterday');
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function isDmFirstInGroup(index: number): boolean {
  const list = directMessages.value ?? [];
  if (index === 0) return true;
  const curr = list[index];
  const prev = list[index - 1];
  if (!curr || !prev) return true;
  if (curr.author.user_id !== prev.author.user_id) return true;
  const diff = new Date(curr.created_at).getTime() - new Date(prev.created_at).getTime();
  return diff > 5 * 60 * 1000 || dmDayKey(curr.created_at) !== dmDayKey(prev.created_at);
}

function isDmLastInGroup(index: number): boolean {
  const list = directMessages.value ?? [];
  const curr = list[index];
  const next = list[index + 1];
  if (!curr || !next) return true;
  if (curr.author.user_id !== next.author.user_id) return true;
  const diff = new Date(next.created_at).getTime() - new Date(curr.created_at).getTime();
  return diff > 5 * 60 * 1000 || dmDayKey(curr.created_at) !== dmDayKey(next.created_at);
}

onBeforeUnmount(() => {
  disposed = true;
  commandSearch.value = null;
  channelAttachmentUpload?.abort();
  directAttachmentUpload?.abort();
  for (const request of directMessageRefreshes.values()) request.abort();
  clearMuteRequests();
  document.removeEventListener('visibilitychange', refreshVisibleChannel);
  document.removeEventListener('visibilitychange', scheduleChannelRead);
  document.removeEventListener('visibilitychange', scheduleDirectRead);
  clearTimeout(directReadTimer);
  clearTimeout(channelReadTimer);
  pendingDirectRead = 0;
  inviteDialogOpen.value = false;
  syncChatChannel(realtime.serverReady.value, null);
  unsubscribeRealtime?.();
});
const directArrivals = useMessageArrivals(() => directMessages.value?.map(m => m.message_id) ?? []);
</script>

<template>
  <div class="flex h-full min-h-0 w-full min-w-0 flex-col overflow-hidden md:flex-row md:gap-3">
    <Dialog :open="directDeleteTarget !== null" @update:open="open => { if (!open && !deletingDirect) closeDirectDelete() }">
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{{ t('chat.actions.deleteMessage') }}</DialogTitle>
          <DialogDescription>{{ t('chat.prompts.deleteDirectMessage') }}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" :disabled="deletingDirect" @click="closeDirectDelete">{{ t('common.cancel') }}</Button>
          <Button variant="destructive" :disabled="deletingDirect" @click="confirmDirectDelete">{{ t('common.delete') }}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
    <div
      data-chat-nav-panel="true"
      class="h-full w-full min-w-0 flex-shrink-0 flex-col overflow-hidden bg-card md:w-[330px] md:rounded-[20px]"
      :class="isMobileNavigationOpen ? 'flex' : 'hidden md:flex'"
    >
      <div class="flex h-full min-h-0 flex-col">
        <div class="m-2.5 grid shrink-0 grid-cols-2 rounded-full bg-secondary p-1">
          <button
            type="button"
            class="flex h-8 items-center justify-center rounded-full text-[13px] transition-all duration-200"
            :class="navTab === 'direct' ? 'bg-card font-semibold text-foreground shadow-xs dark:shadow-none' : 'font-medium text-muted-foreground hover:text-foreground'"
            @click="navTab = 'direct'"
          >
            {{ t('chat.directConversations.title') }}
          </button>
          <button
            type="button"
            class="flex h-8 items-center justify-center rounded-full text-[13px] transition-all duration-200"
            :class="navTab === 'groups' ? 'bg-card font-semibold text-foreground shadow-xs dark:shadow-none' : 'font-medium text-muted-foreground hover:text-foreground'"
            @click="navTab = 'groups'"
          >
            {{ t('nav.main.groups') }}
          </button>
        </div>
        <p v-if="directLinkStatus === 'loading'" class="px-3 py-2 text-xs text-muted-foreground" role="status">
          {{ t('common.loading') }}
        </p>
        <div v-else-if="directLinkStatus === 'failed'" class="space-y-2 px-3 py-2">
          <p class="text-xs text-destructive" role="alert">{{ t('chat.feedback.openDirectConversationFailed') }}</p>
          <div class="flex gap-2">
            <Button size="sm" variant="outline" @click="retryDirectLinkLookup">{{ t('common.retry') }}</Button>
            <Button size="sm" variant="ghost" @click="cancelDirectLinkLookup">{{ t('common.cancel') }}</Button>
          </div>
        </div>
        <div v-if="commandSearch" class="flex items-center justify-between gap-2 px-3 py-2 text-xs text-muted-foreground">
          <p role="status">{{ t('commandPalette.selectConversation') }}</p>
          <Button size="sm" variant="ghost" @click="commandSearch = null">{{ t('common.cancel') }}</Button>
        </div>
        <div v-show="navTab === 'direct'" class="min-h-0 flex-1">
          <ChatDirectConversationList
            class="h-full"
            :conversations="directConversations"
            :active-conversation-id="directConversationId"
            :is-loading="isLoadingDirectConversations"
            :page="directListPage"
            :has-next="hasMoreDirectConversations"
            @change-page="(page: number) => loadDirectConversations(true, page)"
            @select="handleSelectDirectConversation"
            @view-profile="openMemberProfile"
          />
        </div>
        <div v-show="navTab === 'groups'" class="flex min-h-0 flex-1 flex-col">
          <p v-if="loadingGroupChannels" class="px-3 py-2 text-xs text-muted-foreground" role="status">
            {{ t('common.loading') }}
          </p>
          <div v-else-if="channelLoadFailed" class="flex items-center justify-between gap-2 px-3 py-2">
            <p class="text-xs text-destructive" role="alert">{{ t('chat.feedback.loadChannelsFailed') }}</p>
            <Button size="sm" variant="outline" @click="retryGroupChannels">{{ t('common.retry') }}</Button>
          </div>
          <ChatChannelList
            class="flex-1"
            :categories="channelCategories"
            :active-channel-id="activeChannel?.id"
            :group-name="activeGroup?.name"
            :group-avatar="activeGroup?.avatar"
            :groups="groups"
            :has-more-groups="hasMoreGroups"
            :loading-more-groups="isLoading || loadingMoreGroups"
            :active-group-id="activeGroup?.id"
            :can-manage="canManage"
            :current-user-name="currentUserName"
            @select-group="handleSelectGroup"
            @load-more-groups="loadMoreGroups"
            @select="handleSelectChannel"
            @create-channel="handleCreateChannel"
            @edit-channel="handleEditChannel"
            @delete-channel="handleDeleteChannel"
            @toggle-mute="handleToggleChannelMute"
            :is-mute-pending="isMutePending"
            @invite-members="openInviteDialog"
            @notification-settings="openNotificationSettings"
            @settings="openGroupSettings"
          />
        </div>
      </div>
    </div>

    <Dialog :open="createChannelDialogOpen" @update:open="open => { if (!channelWriteBusy) createChannelDialogOpen = open; }">
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
            {{ t(editingChannelId === null ? 'chat.dialogs.createChannel.title' : 'chat.actions.editChannel') }}
          </DialogTitle>
          <DialogDescription class="text-xs text-muted-foreground">
            {{
              editingChannelId === null
                ? t('chat.dialogs.createChannel.description', { category: channelCategory || t('chat.defaultCategoryName') })
                : t('chat.dialogs.createChannel.editDescription')
            }}
          </DialogDescription>
        </DialogHeader>

        <form
          class="grid gap-4 px-5 py-4"
          @submit.prevent="submitChannel"
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
              :disabled="channelWriteBusy"
              autocomplete="off"
              class="h-9 shadow-xs"
            />
            <p v-if="channelNameBytes > 100" class="text-xs text-destructive">
              {{ t('chat.dialogs.createChannel.byteLimit', { max: 100 }) }}
            </p>
          </div>
          <div class="grid gap-2">
            <Label for="chat-channel-category">{{ t('chat.dialogs.createChannel.categoryLabel') }}</Label>
            <Input id="chat-channel-category" v-model="channelCategory" :disabled="channelWriteBusy" />
            <p v-if="channelCategoryBytes > 50" class="text-xs text-destructive">
              {{ t('chat.dialogs.createChannel.byteLimit', { max: 50 }) }}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <Switch id="chat-channel-private" v-model="channelPrivate" :disabled="channelWriteBusy" />
            <Label for="chat-channel-private">{{ t('chat.dialogs.createChannel.privateLabel') }}</Label>
          </div>

          <DialogFooter
            class="-mx-5 -mb-4 mt-1 border-t border-border/60 bg-background/60 px-5 py-3"
          >
            <Button
              type="button"
              variant="outline"
              size="sm"
              class="h-9 rounded-md shadow-xs"
              :disabled="channelWriteBusy"
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
                v-if="channelWriteBusy"
                class="h-3.5 w-3.5 animate-spin"
              />
              {{
                channelWriteBusy
                  ? t('common.processing')
                  : t(editingChannelId === null ? 'common.create' : 'common.submit')
              }}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>

    <Dialog :open="inviteDialogOpen" @update:open="value => { if (!isCreatingInvite) inviteDialogOpen = value; }">
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
                  :disabled="isCreatingInvite || inviteResultUnknown"
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
                :disabled="isCreatingInvite || inviteResultUnknown"
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
                  :disabled="isCreatingInvite || inviteResultUnknown"
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
                  :disabled="pendingInvitee !== null || isCreatingInvite || inviteResultUnknown"
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
                  :disabled="isCreatingInvite || inviteResultUnknown"
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
                :disabled="isCreatingInvite || inviteResultUnknown"
              />
            </div>

            <p v-if="inviteResultUnknown" role="alert" class="text-sm text-destructive">
              {{ t('chat.invite.resultUnknown') }}
            </p>
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
                  class="size-8 shrink-0"
                  :aria-label="t('common.copy')"
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
            :disabled="isCreatingInvite || isSearchingInviteUsers || !activeGroup || inviteResultUnknown || pendingInvitee === undefined"
            @click="submitInvite"
          >
            <Loader2
              v-if="isCreatingInvite"
              class="h-3.5 w-3.5 animate-spin"
            />
            {{
              isCreatingInvite
                ? t('common.processing')
                : pendingInvitee !== null
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
                :disabled="isMutePending(channel.id)"
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
      class="h-full min-h-0 flex-1 min-w-0 overflow-hidden bg-card md:rounded-[20px]"
      :class="isMobileNavigationOpen ? 'hidden md:block' : 'block'"
    >
      <MotionMessageSkeleton v-if="isLoading && !activeChannel" />
      <div
        v-else-if="errorMessage"
        class="flex h-full items-center justify-center p-6"
      >
        <div
          class="flex max-w-md flex-col items-center gap-3 rounded-[20px] bg-rose-500/8 p-8 text-center"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/12 text-rose-600 dark:text-rose-400"
          >
            <AlertTriangle class="h-5 w-5" />
          </span>
          <p class="text-sm text-rose-700 dark:text-rose-200">
            {{ errorMessage }}
          </p>
          <Button
            variant="secondary"
            size="sm"
            class="h-8 rounded-full"
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
          class="flex max-w-md flex-col items-center gap-3 rounded-[20px] bg-secondary/45 p-8 text-center text-sm text-muted-foreground"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-card text-muted-foreground"
          >
            <Inbox class="h-5 w-5" />
          </span>
          {{
            navTab === 'direct' || directConversations.length > 0
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
          <div class="flex items-center gap-3 bg-[var(--glass-bg)] px-4 py-3 backdrop-blur-md">
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
              <UserAvatar
                :src="directMessageStandaloneTarget.avatar"
                :name="directMessageStandaloneTarget.nickname"
                :username="directMessageStandaloneTarget.username"
                :seed="directMessageStandaloneTarget.id"
                size="md"
              />
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
            <Button type="button" variant="ghost" size="icon" :aria-label="t('chat.actions.searchMessages')"
              :aria-expanded="standaloneDirectSearchOpen" @click="toggleStandaloneDirectSearch">
              <Search class="h-4 w-4" />
            </Button>
            <Button type="button" variant="ghost" size="icon" :aria-label="t('chat.actions.startVoiceCall')"
              @click="startChatCall(directMessageStandaloneTarget,'voice')"><Phone class="h-4 w-4" /></Button>
            <Button type="button" variant="ghost" size="icon" :aria-label="t('chat.actions.startVideoCall')"
              @click="startChatCall(directMessageStandaloneTarget,'video')"><Video class="h-4 w-4" /></Button>
          </div>

          <ChatSearchFilters v-if="standaloneDirectSearchOpen" :initial-keyword="directSearch?.q" :senders="[
            { id: currentUserId, label: currentUserName },
            { id: directMessageStandaloneTarget.id, label: directMessageStandaloneTarget.nickname },
          ]" @search="handleDirectSearch" />

          <div class="relative min-h-0 flex-1">
            <ScrollArea class="h-full">
              <div class="min-h-full px-4 py-4">
                <Button v-if="hasOlderDirectMessages && !isLoadingDirectMessages" variant="outline" size="sm" class="mb-3" :disabled="loadingOlderDirectMessages" @click="loadOlderDirectMessages">
                  {{ t('chat.directMessage.loadOlder') }}
                </Button>
                <MotionSkeletonSwap>
                <MotionMessageSkeleton v-if="isLoadingDirectMessages && !directMessages?.length" />

                <div
                  v-else-if="!directMessages?.length"
                  class="flex min-h-[40vh] flex-col items-center justify-center text-center text-muted-foreground"
                >
                  <div class="font-medium text-foreground">
                    {{ t(directSearch ? 'chat.messageSearch.empty' : 'chat.directMessage.emptyTitle') }}
                  </div>
                  <div v-if="!directSearch" class="mt-1 text-sm">
                    {{ t('chat.directMessage.emptyDescription') }}
                  </div>
                </div>

                <div v-else data-message-list ref="standaloneDirectList" class="flex flex-col pb-4">
                  <div
                    v-for="(message, index) in directMessages"
                    :key="message.message_id"
                    :data-incoming-direct-message-id="message.author.user_id !== currentUserId ? message.message_id : undefined"
                  >
                    <div
                      v-if="shouldShowDmDatePill(index)"
                      class="my-3 flex justify-center"
                    >
                      <span class="rounded-full bg-[var(--hover)] px-3 py-1 text-[11px] font-semibold text-muted-foreground">
                        {{ formatDmDatePill(message.created_at) }}
                      </span>
                    </div>
                    <ChatMessage
                      :message="mapV2DirectMessage(message)"
                      :animate="!directSearch && directArrivals.has(message.message_id)"
                      :is-own="message.author.user_id === currentUserId"
                      :allow-edit="false"
                      :hide-reply="directSearch !== null"
                      :allow-delete="canDeleteDirectMessage(message)"
                      show-avatar
                      :is-first-in-group="isDmFirstInGroup(index)"
                      :is-last-in-group="isDmLastInGroup(index)"
                      @reply="standaloneDirectReplyId = $event.id"
                      @react="handleDirectReaction"
                      @delete="requestDirectDelete(message)"
                      @view-profile="openMemberProfile"
                    />
                    <p v-if="!directSearch && message.message_id === lastSeenOwnDirectMessage" class="px-4 text-right text-xs text-muted-foreground">
                      {{ t('chat.directMessage.read') }}
                    </p>
                  </div>
                </div>
              </MotionSkeletonSwap>
              </div>
            </ScrollArea>
          </div>

          <div
            v-if="!directSearch && directTyping.typingCount.value"
            class="flex items-center gap-2 px-4 py-1 text-xs text-muted-foreground"
            role="status"
          >
            <span class="inline-flex items-center gap-0.5" aria-hidden="true">
              <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 0ms" />
              <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 150ms" />
              <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 300ms" />
            </span>
            <span>
              {{ t('chat.directMessage.typing', { user: directMessageStandaloneTarget.nickname }) }}
            </span>
          </div>
          <ChatInput
            v-show="!directSearch"
            :key="directSelectionRevision"
            :placeholder="t('chat.directMessage.placeholder', { user: directMessageStandaloneTarget.nickname })"
            :disabled="isLoadingDirectMessages"
            :reply-to="standaloneDirectReply"
            :send-message="submitStandaloneDirectMessage"
            @typing="directTyping.edit"
            @cancel-reply="standaloneDirectReplyId = null"
          />
        </div>

        <ChatRoom
          v-else-if="activeChannel"
          :channel="activeChannel"
          :mute-pending="isMutePending(activeChannel.id)"
          :messages="messages"
          :members="members"
          :pinned-messages="pinnedMessages"
          :can-manage="canManage"
          :is-loading="isLoadingMessages"
          :message-load-failed="failedMessageLoad !== null"
          :is-sending="isSending"
          :current-user-id="currentUserId"
          :direct-messages="directMessages"
          :channel-search-active="channelSearch !== null"
          :direct-search-active="directSearch !== null"
          :channel-search-keyword="channelSearch?.q"
          :direct-search-keyword="directSearch?.q"
          :current-user-name="currentUserName"
          :channel-typing-count="channelTyping.typingCount.value"
          :direct-typing="directTyping.typingCount.value > 0"
          :last-seen-own-direct-message="lastSeenOwnDirectMessage"
          :is-loading-direct-messages="isLoadingDirectMessages"
          :has-older-direct-messages="hasOlderDirectMessages"
          :loading-older-direct-messages="loadingOlderDirectMessages"
          :channels="chatChannels"
          :show-mobile-navigation-toggle="true"
          :composer-revision="channelComposerRevision"
          :send-message="handleSendMessage"
          @load-more="handleLoadMore"
          @retry-history="retryChannelHistory"
          @react="handleReact"
          @edit="handleEditMessage"
          @delete="handleDeleteMessage"
          @pin="handlePinMessage"
          @toggle-mute="() => handleToggleChannelMute()"
          @search="handleSearch"
          @direct-search="handleDirectSearch"
          @show-navigation="showMobileNavigation"
          @view-profile="openMemberProfile"
          @open-direct-message="handleOpenDirectMessage"
          @open-direct-message-standalone="handleOpenDirectMessageStandalone"
          :send-direct-message="handleSendDirectMessage"
          @react-direct-message="handleDirectReaction"
          @typing-channel="channelTyping.edit"
          @typing-direct="directTyping.edit"
          @direct-visibility="onDirectSheetVisibility"
          @direct-message-visible="markVisibleDirectMessage"
          @start-call="startChatCall"
          @delete-direct-message="requestDirectDelete"
          @load-older-direct-messages="loadOlderDirectMessages"
        />

        <div
          v-else
          class="h-full flex items-center justify-center text-muted-foreground"
        >
          {{ t(loadingGroupChannels ? 'common.loading' : channelLoadFailed
            ? 'chat.feedback.loadChannelsFailed' : 'chat.empty.noChannels') }}
        </div>
      </template>
    </div>
  </div>
</template>
