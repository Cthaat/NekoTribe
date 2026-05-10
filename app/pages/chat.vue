<script setup lang="ts">
import {
  computed,
  onBeforeUnmount,
  onMounted,
  ref
} from 'vue';
import { toast } from 'vue-sonner';
import ChatChannelList from '@/components/ChatChannelList.vue';
import ChatRoom from '@/components/ChatRoom.vue';
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
import {
  buildChatChannelCategories,
  mapV2ChatGroup,
  mapV2ChatMember,
  mapV2ChatMessage,
  replaceChatMessage,
  type ChatGroupVM
} from '@/services/chat';
import { usePreferenceStore } from '@/stores/user';
import type {
  V2ChatMessage,
  V2DirectMessage
} from '@/types/v2';

const { t } = useAppLocale();

definePageMeta({
  layout: 'chat'
});

interface ChatWsEvent {
  type: string;
  data?: {
    channel_id?: number;
    conversation_id?: number;
    message_id?: number;
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
const directConversationId = ref<number | null>(null);
const directMessageTargetId = ref<number | null>(null);
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
let searchTimer: ReturnType<typeof setTimeout> | null = null;

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

function sendWs(payload: Record<string, unknown>): void {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
  }
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

function handleWsMessage(event: MessageEvent<string>): void {
  let payload: ChatWsEvent;
  try {
    payload = JSON.parse(event.data) as ChatWsEvent;
  } catch {
    return;
  }

  const channelId = payload.data?.channel_id;
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
    if (activeChannel.value) {
      joinWsChannel(activeChannel.value.id);
    }
  };
  ws.onmessage = handleWsMessage;
  ws.onclose = () => {
    ws = null;
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

function handleLoadMore(): void {
  if (!activeChannel.value || !hasMoreMessages.value) return;
  void loadMessages(activeChannel.value.id, false);
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
  if (searchTimer) clearTimeout(searchTimer);
  if (activeChannel.value) {
    leaveWsChannel(activeChannel.value.id);
  }
  ws?.close();
});
</script>

<template>
  <div class="flex h-full min-h-0 w-full overflow-hidden">
    <div
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
        <button
          class="text-sm text-primary hover:underline"
          @click="loadChat"
        >
          {{ t('common.refresh') }}
        </button>
      </div>
      <div
        v-else-if="!activeGroup"
        class="h-full flex items-center justify-center text-muted-foreground"
      >
        {{ t('chat.empty.noGroups') }}
      </div>
      <div
        v-else-if="!activeChannel"
        class="h-full flex items-center justify-center text-muted-foreground"
      >
        {{ t('chat.empty.noChannels') }}
      </div>
      <ChatRoom
        v-else
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
        @send="handleSendMessage"
        @load-more="handleLoadMore"
        @react="handleReact"
        @edit="handleEditMessage"
        @delete="handleDeleteMessage"
        @pin="handlePinMessage"
        @toggle-mute="() => handleToggleChannelMute()"
        @search="handleSearch"
        @open-direct-message="handleOpenDirectMessage"
        @send-direct-message="handleSendDirectMessage"
      />
    </div>
  </div>
</template>
