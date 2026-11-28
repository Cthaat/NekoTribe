<script setup lang="ts">
import {
  type ComponentPublicInstance,
  ref,
  computed,
  onMounted,
  onBeforeUnmount,
  nextTick,
  watch
} from 'vue';
import {
  Hash,
  Pin,
  Bell,
  BellOff,
  Search,
  Phone,
  Video,
  PanelLeftOpen,
  PanelRightClose,
  PanelRightOpen,
  ArrowDown,
  Maximize2
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Switch } from '@/components/ui/switch';
import { Label } from '@/components/ui/label';
import { ScrollArea } from '@/components/ui/scroll-area';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger
} from '@/components/ui/sheet';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import UserAvatar from '@/components/UserAvatar.vue';
import ChatMessage from './ChatMessage.vue';
import ChatInput from './ChatInput.vue';
import ChatSearchFilters from './ChatSearchFilters.vue';
import ChatMemberList from './ChatMemberList.vue';
import { mapV2DirectMessage } from '@/services/chat';
import { useDirectMessageViewport } from '@/composables/useDirectMessageViewport';
import type { ChatMessageType } from './ChatMessage.vue';
import type { ChatMember } from './ChatMemberList.vue';
import type { Channel } from './ChatChannelList.vue';
import type { V2DirectMessage } from '@/types/v2';
import type { ChatMessageFilters } from '@/api/v2/chat';
import type { CallMode } from '@/api/v2/webrtc';
import { useMediaQuery } from '@vueuse/core';
import { toast } from 'vue-sonner';
const narrowSheet = useMediaQuery('(max-width: 639px)');
const { t, locale } = useAppLocale();

const props = defineProps<{
  channel: Channel;
  messages: ChatMessageType[];
  members: ChatMember[];
  pinnedMessages?: ChatMessageType[];
  canManage?: boolean;
  mutePending?: boolean;
  isLoading?: boolean;
  messageLoadFailed?: boolean;
  isSending?: boolean;
  currentUserId?: number;
  currentUserName?: string;
  directMessages?: V2DirectMessage[];
  channelSearchActive?: boolean;
  directSearchActive?: boolean;
  channelSearchKeyword?: string;
  directSearchKeyword?: string;
  channelTypingCount?: number;
  directTyping?: boolean;
  lastSeenOwnDirectMessage?: number;
  isLoadingDirectMessages?: boolean;
  hasOlderDirectMessages?: boolean;
  loadingOlderDirectMessages?: boolean;
  channels?: Channel[];
  showMobileNavigationToggle?: boolean;
  composerRevision: number;
  sendMessage: (content: string, attachments?: File[], replyToMessageId?: number) => Promise<boolean>;
  sendDirectMessage: (targetUserId: number, content: string, attachments?: File[], replyToMessageId?: number) => Promise<boolean>;
}>();

const emit = defineEmits<{
  (e: 'load-more'): void;
  (e: 'retry-history'): void;
  (e: 'load-older-direct-messages'): void;
  (e: 'react', messageId: number, emoji: string): void;
  (e: 'reply', message: ChatMessageType): void;
  (e: 'edit', message: ChatMessageType): void;
  (e: 'delete', messageId: number): void;
  (e: 'pin', messageId: number): void;
  (e: 'toggle-mute'): void;
  (e: 'search', filters: ChatMessageFilters | null): void;
  (e: 'direct-search', filters: ChatMessageFilters | null): void;
  (e: 'show-navigation'): void;
  (e: 'view-profile', userId: number): void;
  (e: 'open-direct-message', member: ChatMember): void;
  (e: 'open-direct-message-standalone', member: ChatMember): void;
  (e: 'delete-direct-message', message: V2DirectMessage): void;
  (e: 'react-direct-message', messageId: number, emoji: string): void;
  (e: 'typing-channel', active: boolean): void;
  (e: 'typing-direct', active: boolean): void;
  (e: 'direct-visibility', open: boolean): void;
  (e: 'direct-message-visible', messageId: number): void;
  (e: 'start-call', member: ChatMember, mode: CallMode): void;
}>();

// 状态
const showMemberList = ref(true);
const mobileMemberListOpen = ref(false);
const showPinnedMessages = ref(false);
const showSearch = ref(false);
const showDirectSearch = ref(false);
watch(() => props.channelSearchActive, active => { if (active) showSearch.value = true; }, { immediate: true });
watch(() => props.directSearchActive, active => { if (active) showDirectSearch.value = true; }, { immediate: true });
const notificationSettingsOpen = ref(false);
const callDialogOpen = ref(false);
const callDialogType = ref<CallMode>('voice');
const callMemberId = ref<number | ''>('');
const callMembers = computed(() => props.members.filter(member => member.id !== props.currentUserId));
const directMessageOpen = ref(false);
const directList = ref<HTMLElement | null>(null);
const directMessageTarget = ref<ChatMember | null>(null);
const directDraftRevision = ref(0);
const directReplyId = ref<number | null>(null);
const directReply = computed(() => {
  const message = props.directMessages?.find(item => item.message_id === directReplyId.value);
  return message ? mapV2DirectMessage(message) : null;
});
watch(directMessageOpen, open => emit('direct-visibility', open), { flush: 'sync' });
useDirectMessageViewport(directList, () => props.directMessages?.map(item => item.message_id).join(',') ?? '',
  () => directMessageOpen.value && !props.directSearchActive, id => emit('direct-message-visible', id));
const channelSearchSenders = computed(() => {
  const senders = new Map(props.members.map(member => [member.id, member.nickname || member.username]));
  for (const {author} of props.messages) {
    if (!senders.has(author.id)) senders.set(author.id, author.nickname || author.username);
  }
  return Array.from(senders, ([id, label]) => ({id,label}));
});
const replyTo = ref<ChatMessageType | null>(null);
const messagesScrollAreaRef =
  ref<ComponentPublicInstance | null>(null);
const messagesContainerRef = ref<HTMLElement | null>(null);
const isAtBottom = ref(true);
const hasNewMessages = ref(false);

const canSendInChannel = computed(() => {
  if (props.channel.type === 'text') return true;
  if (props.channel.type === 'announcement') {
    return props.canManage === true;
  }
  return false;
});

const composerDisabledReason = computed(() => {
  if (
    props.channel.type === 'announcement' &&
    props.canManage !== true
  ) {
    return t('chat.input.announcementReadOnly');
  }
  if (!canSendInChannel.value) {
    return t('chat.input.unsupportedChannel');
  }
  return '';
});

const isComposerDisabled = computed(
  () =>
    props.isSending === true || !canSendInChannel.value
);

// 判断消息是否是同一组的第一条（同一用户连续发送）
const isFirstInGroup = (index: number) => {
  if (index === 0) return true;
  const currentMsg = props.messages[index];
  const prevMsg = props.messages[index - 1];
  if (!currentMsg || !prevMsg) return true;

  // 系统消息始终独立
  if (currentMsg.type === 'system') return true;
  if (prevMsg.type === 'system') return true;

  // 不同作者
  if (currentMsg.author.id !== prevMsg.author.id)
    return true;

  // 时间间隔超过5分钟
  const currentTime = new Date(
    currentMsg.createdAt
  ).getTime();
  const prevTime = new Date(prevMsg.createdAt).getTime();
  if (currentTime - prevTime > 5 * 60 * 1000) return true;
  if (dayKey(currentMsg.createdAt) !== dayKey(prevMsg.createdAt)) return true;

  return false;
};

const isLastInGroup = (index: number) => {
  const currentMsg = props.messages[index];
  const nextMsg = props.messages[index + 1];
  if (!currentMsg || !nextMsg) return true;
  if (currentMsg.type === 'system' || nextMsg.type === 'system') return true;
  if (currentMsg.author.id !== nextMsg.author.id) return true;
  const currentTime = new Date(currentMsg.createdAt).getTime();
  const nextTime = new Date(nextMsg.createdAt).getTime();
  if (nextTime - currentTime > 5 * 60 * 1000) return true;
  return dayKey(currentMsg.createdAt) !== dayKey(nextMsg.createdAt);
};

function dayKey(dateStr: string): string {
  const d = new Date(dateStr);
  if (Number.isNaN(d.getTime())) return '';
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

function shouldShowDateSeparator(index: number): boolean {
  const msg = props.messages[index];
  if (!msg) return false;
  if (index === 0) return true;
  const prev = props.messages[index - 1];
  return !prev || dayKey(msg.createdAt) !== dayKey(prev.createdAt);
}

function formatDateSeparator(dateStr: string): string {
  const d = new Date(dateStr);
  if (Number.isNaN(d.getTime())) return '';
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const target = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diffDays = Math.round((today - target) / 86400000);
  if (diffDays === 0) return t('chat.dateToday');
  if (diffDays === 1) return t('chat.dateYesterday');
  return d.toLocaleDateString(locale.value === 'en' ? 'en-US' : 'zh-CN', {
    month: 'short',
    day: 'numeric'
  });
}

function isDmFirstInGroup(index: number): boolean {
  const list = props.directMessages ?? [];
  if (index === 0) return true;
  const curr = list[index];
  const prev = list[index - 1];
  if (!curr || !prev) return true;
  if (curr.author.user_id !== prev.author.user_id) return true;
  const diff = new Date(curr.created_at).getTime() - new Date(prev.created_at).getTime();
  return diff > 5 * 60 * 1000 || dayKey(curr.created_at) !== dayKey(prev.created_at);
}

function isDmLastInGroup(index: number): boolean {
  const list = props.directMessages ?? [];
  const curr = list[index];
  const next = list[index + 1];
  if (!curr || !next) return true;
  if (curr.author.user_id !== next.author.user_id) return true;
  const diff = new Date(next.created_at).getTime() - new Date(curr.created_at).getTime();
  return diff > 5 * 60 * 1000 || dayKey(curr.created_at) !== dayKey(next.created_at);
}

function shouldShowDmDateSeparator(index: number): boolean {
  const list = props.directMessages ?? [];
  const msg = list[index];
  if (!msg) return false;
  if (index === 0) return true;
  const prev = list[index - 1];
  return !prev || dayKey(msg.created_at) !== dayKey(prev.created_at);
}

// 是否显示头像
const shouldShowAvatar = (index: number) => {
  return isLastInGroup(index);
};

// 是否是自己的消息
const isOwnMessage = (message: ChatMessageType) => {
  return (
    props.currentUserId !== undefined &&
    message.author.id === props.currentUserId
  );
};

const openCallDialog = (type: CallMode) => {
  callDialogType.value = type;
  callMemberId.value = '';
  callDialogOpen.value = true;
};

const handleStartCall = () => {
  const member = callMembers.value.find(item => item.id === callMemberId.value);
  if (!member) return;
  callDialogOpen.value = false;
  emit('start-call',member,callDialogType.value);
};

function getMessagesViewport(): HTMLElement | null {
  const root = messagesScrollAreaRef.value?.$el;
  if (!(root instanceof HTMLElement)) return null;
  return root.querySelector<HTMLElement>(
    '[data-slot="scroll-area-viewport"]'
  );
}

const openDirectMessage = (member: ChatMember) => {
  if (member.id === props.currentUserId) {
    toast.info(t('chat.feedback.cannotMessageSelf'));
    return;
  }
  directMessageTarget.value = member;
  showDirectSearch.value = false;
  directDraftRevision.value++;
  directReplyId.value = null;
  directMessageOpen.value = true;
  emit('open-direct-message', member);
};

const openDirectMessageStandalone = () => {
  if (!directMessageTarget.value) return;
  emit('open-direct-message-standalone', directMessageTarget.value);
};

const submitDirectMessage = async (content: string, attachments?: File[]): Promise<boolean> => {
  const target = directMessageTarget.value;
  if (!target) return false;
  const revision = directDraftRevision.value;
  const replyId = directReply.value?.id;
  const sent = await props.sendDirectMessage(target.id, content, attachments, replyId);
  if (sent && directMessageOpen.value && revision === directDraftRevision.value && directReplyId.value === replyId) {
    directReplyId.value = null;
  }
  return sent;
};

// 滚动到底部
const scrollToBottom = async (smooth = true) => {
  await nextTick();
  if (messagesContainerRef.value) {
    messagesContainerRef.value.scrollTo({
      top: messagesContainerRef.value.scrollHeight,
      behavior: smooth ? 'smooth' : 'auto'
    });
  }
};

// 处理滚动
const handleScroll = () => {
  if (messagesContainerRef.value) {
    const { scrollTop, scrollHeight, clientHeight } =
      messagesContainerRef.value;
    isAtBottom.value =
      scrollHeight - scrollTop - clientHeight < 100;

    if (isAtBottom.value) {
      hasNewMessages.value = false;
    }

    // 加载更多
    if (scrollTop < 100) {
      emit('load-more');
    }
  }
};

// 处理发送
const handleSend = async (
  content: string,
  attachments?: File[]
): Promise<boolean> => {
  if (isComposerDisabled.value) return false;
  const revision = props.composerRevision;
  const replyId = replyTo.value?.id;
  const sent = await props.sendMessage(content, attachments, replyId);
  if (!sent || revision !== props.composerRevision) return false;
  if (replyTo.value?.id === replyId) replyTo.value = null;
  scrollToBottom();
  return true;
};

watch(() => props.composerRevision, () => {
  replyTo.value = null;
  showSearch.value = false;
  showDirectSearch.value = false;
  directDraftRevision.value++;
  directMessageOpen.value = false;
  directMessageTarget.value = null;
  directReplyId.value = null;
});

function toggleSearch() {
  showSearch.value = !showSearch.value;
  if (!showSearch.value) emit('search', null);
}

function toggleDirectSearch() {
  showDirectSearch.value = !showDirectSearch.value;
  if (!showDirectSearch.value) emit('direct-search', null);
}

// 处理回复
const handleReply = (message: ChatMessageType) => {
  replyTo.value = message;
};

// 取消回复
const cancelReply = () => {
  replyTo.value = null;
};

// 复制消息
const handleCopy = (content: string) => {
  navigator.clipboard.writeText(content);
  toast.success(t('chat.feedback.copied'));
};

// 监听新消息
watch(
  () => props.messages.length,
  (newLen, oldLen) => {
    if (newLen > oldLen) {
      if (isAtBottom.value) {
        scrollToBottom();
      } else {
        hasNewMessages.value = true;
      }
    }
  }
);

// 初始滚动到底部
onMounted(async () => {
  await nextTick();
  messagesContainerRef.value = getMessagesViewport();
  messagesContainerRef.value?.addEventListener(
    'scroll',
    handleScroll,
    { passive: true }
  );
  scrollToBottom(false);
});

onBeforeUnmount(() => {
  messagesContainerRef.value?.removeEventListener(
    'scroll',
    handleScroll
  );
});
</script>

<template>
  <div class="flex h-full min-h-0 overflow-hidden">
    <!-- 主聊天区域 -->
    <div class="flex min-h-0 flex-1 flex-col overflow-hidden min-w-0">
      <!-- 频道头部 -->
      <div
        class="flex h-13 shrink-0 items-center justify-between gap-2 bg-[var(--glass-bg)] px-3 backdrop-blur-md sm:px-4"
      >
        <div class="flex min-w-0 items-center gap-2">
          <Button
            v-if="showMobileNavigationToggle"
            variant="ghost"
            size="icon"
            class="h-8 w-8 shrink-0 rounded-md text-muted-foreground hover:text-foreground md:hidden"
            @click="emit('show-navigation')"
          >
            <PanelLeftOpen class="h-4 w-4" />
            <span class="sr-only">
              {{ t('chat.backToChannels') }}
            </span>
          </Button>
          <Hash class="h-4 w-4 shrink-0 text-muted-foreground" />
          <span class="truncate text-sm font-semibold">
            {{ channel.name }}
          </span>
          <span class="mx-1 hidden h-4 w-px bg-border sm:block" aria-hidden="true" />
          <span
            class="hidden max-w-xs truncate text-xs text-muted-foreground sm:inline"
          >
            {{
              channel.lastMessage ||
              t('chat.channelDescriptionFallback')
            }}
          </span>
        </div>

        <div class="flex items-center gap-0.5">
          <TooltipProvider>
            <!-- 语音通话 -->
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                    class="size-8 text-muted-foreground hover:text-foreground"
                    :aria-label="t('chat.actions.startVoiceCall')"
                  @click="openCallDialog('voice')"
                >
                  <Phone class="h-4 w-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                <p>{{ t('chat.actions.startVoiceCall') }}</p>
              </TooltipContent>
            </Tooltip>

            <!-- 视频通话 -->
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                    class="size-8 text-muted-foreground hover:text-foreground"
                    :aria-label="t('chat.actions.startVideoCall')"
                  @click="openCallDialog('video')"
                >
                  <Video class="h-4 w-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                <p>{{ t('chat.actions.startVideoCall') }}</p>
              </TooltipContent>
            </Tooltip>

            <!-- 置顶消息 -->
            <Sheet v-model:open="showPinnedMessages">
              <Tooltip>
                <TooltipTrigger as-child>
                  <SheetTrigger as-child>
                    <Button
                      variant="ghost"
                      size="icon"
                      class="relative h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
                    >
                      <Pin class="h-4 w-4" />
                      <span
                        v-if="pinnedMessages?.length"
                        class="absolute -right-0.5 -top-0.5 inline-flex h-4 min-w-[16px] items-center justify-center rounded-full bg-primary px-1 text-[10px] font-medium tabular-nums text-primary-foreground"
                      >
                        {{ pinnedMessages.length }}
                      </span>
                    </Button>
                  </SheetTrigger>
                </TooltipTrigger>
                <TooltipContent>
                  <p>{{ t('chat.message.pinnedMessages') }}</p>
                </TooltipContent>
              </Tooltip>
              <SheetContent :side="narrowSheet ? 'bottom' : 'right'" class="w-full sm:w-80">
                <SheetHeader>
                  <SheetTitle class="text-base font-semibold tracking-tight">
                    {{ t('chat.message.pinnedMessages') }}
                  </SheetTitle>
                </SheetHeader>
                <div class="mt-4 space-y-2 px-2">
                  <div
                    v-if="!pinnedMessages?.length"
                    class="mx-auto flex max-w-xs flex-col items-center justify-center rounded-[18px] bg-secondary/50 px-4 py-8 text-center"
                  >
                    <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-card">
                      <Pin class="h-4 w-4 text-muted-foreground" />
                    </div>
                    <p class="text-xs text-muted-foreground">
                      {{ t('chat.message.noPinnedMessages') }}
                    </p>
                  </div>
                  <div
                    v-for="msg in pinnedMessages"
                    :key="msg.id"
                    class="rounded-[18px] bg-secondary/50 p-3 transition-colors hover:bg-secondary"
                  >
                    <div class="mb-1 flex items-center gap-2">
                      <span class="truncate text-sm font-medium">
                        {{ msg.author.nickname }}
                      </span>
                      <span class="text-[11px] tabular-nums text-muted-foreground">
                        {{ new Date(msg.createdAt).toLocaleDateString() }}
                      </span>
                    </div>
                    <p class="text-sm leading-relaxed text-foreground">
                      {{ msg.content }}
                    </p>
                  </div>
                </div>
              </SheetContent>
            </Sheet>

            <!-- 通知设置 -->
            <Sheet v-model:open="notificationSettingsOpen">
              <Tooltip>
                <TooltipTrigger as-child>
                  <SheetTrigger as-child>
                    <Button
                      variant="ghost"
                      size="icon"
                        class="size-8 text-muted-foreground hover:text-foreground"
                        :aria-label="t('chat.actions.notificationSettings')"
                    >
                      <component
                        :is="channel.isMuted ? BellOff : Bell"
                        class="h-4 w-4"
                      />
                    </Button>
                  </SheetTrigger>
                </TooltipTrigger>
                <TooltipContent>
                  <p>{{ t('chat.actions.notificationSettings') }}</p>
                </TooltipContent>
              </Tooltip>
              <SheetContent :side="narrowSheet ? 'bottom' : 'right'" class="w-full p-6 sm:w-80">
                <SheetHeader>
                  <SheetTitle class="text-base font-semibold tracking-tight">
                    {{ t('chat.notifications.title') }}
                  </SheetTitle>
                </SheetHeader>
                <div class="mt-6">
                  <div
                    class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-card p-3"
                  >
                    <div class="space-y-0.5">
                      <Label class="text-sm font-medium">
                        {{ t('chat.notifications.muteLabel') }}
                      </Label>
                      <p class="text-xs leading-relaxed text-muted-foreground">
                        {{ t('chat.notifications.muteDescription') }}
                      </p>
                    </div>
                    <Switch
                      :model-value="channel.isMuted"
                      :disabled="mutePending"
                      @update:model-value="emit('toggle-mute')"
                    />
                  </div>
                </div>
              </SheetContent>
            </Sheet>

            <!-- 搜索 -->
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
                  :class="{ 'bg-accent text-accent-foreground': showSearch }"
                  :aria-label="t('chat.actions.searchMessages')"
                  :aria-expanded="showSearch"
                  @click="toggleSearch"
                >
                  <Search class="h-4 w-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                <p>{{ t('chat.actions.searchMessages') }}</p>
              </TooltipContent>
            </Tooltip>

            <!-- 成员列表切换 -->
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                    class="size-8 text-muted-foreground hover:text-foreground lg:hidden"
                    :aria-label="t('chat.actions.showMembers')"
                    :aria-expanded="mobileMemberListOpen"
                  @click="mobileMemberListOpen = true"
                >
                  <PanelRightOpen class="h-4 w-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                <p>{{ t('chat.actions.showMembers') }}</p>
              </TooltipContent>
            </Tooltip>
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                    class="hidden size-8 text-muted-foreground hover:text-foreground lg:inline-flex"
                    :aria-label="t(showMemberList ? 'chat.actions.hideMembers' : 'chat.actions.showMembers')"
                    :aria-expanded="showMemberList"
                  :class="{ 'bg-accent text-accent-foreground': showMemberList }"
                  @click="showMemberList = !showMemberList"
                >
                  <component
                    :is="
                      showMemberList
                        ? PanelRightClose
                        : PanelRightOpen
                    "
                    class="h-4 w-4"
                  />
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                <p>
                  {{
                    showMemberList
                      ? t('chat.actions.hideMembers')
                      : t('chat.actions.showMembers')
                  }}
                </p>
              </TooltipContent>
            </Tooltip>
          </TooltipProvider>
        </div>
      </div>

      <!-- 搜索栏 -->
      <ChatSearchFilters v-if="showSearch" :senders="channelSearchSenders" :initial-keyword="channelSearchKeyword" @search="emit('search', $event)" />

      <!-- 消息区域 -->
      <div class="relative min-h-0 flex-1">
        <ScrollArea
          ref="messagesScrollAreaRef"
          class="h-full"
        >
          <div class="min-h-full">
            <!-- 加载中 -->
            <div
              v-if="isLoading"
              class="flex justify-center py-6"
            >
              <div class="h-5 w-5 animate-spin rounded-full border-2 border-muted-foreground/30 border-t-primary" />
            </div>
            <div v-else-if="messageLoadFailed" class="flex items-center justify-center gap-3 px-3 py-3">
              <p class="text-sm text-destructive" role="alert">{{ t('chat.feedback.loadMessagesFailed') }}</p>
              <Button size="sm" variant="outline" @click="emit('retry-history')">{{ t('common.retry') }}</Button>
            </div>

            <!-- 消息列表 -->
            <div class="py-3">
              <template
                v-for="(message, index) in messages"
                :key="message.id"
              >
                <div
                  v-if="shouldShowDateSeparator(index)"
                  class="my-3 flex justify-center"
                >
                  <span class="rounded-full bg-[var(--hover)] px-3 py-1 text-[11px] font-semibold text-muted-foreground">
                    {{ formatDateSeparator(message.createdAt) }}
                  </span>
                </div>
                <ChatMessage
                  :message="message"
                  :is-own="isOwnMessage(message)"
                  :allow-edit="!channelSearchActive"
                  :hide-reply="channelSearchActive"
                  :show-avatar="shouldShowAvatar(index)"
                  :is-first-in-group="isFirstInGroup(index)"
                  :is-last-in-group="isLastInGroup(index)"
                  @reply="handleReply"
                  @edit="emit('edit', $event)"
                  @delete="emit('delete', $event)"
                  @pin="emit('pin', $event)"
                  @react="
                    (id: number, emoji: string) =>
                      emit('react', id, emoji)
                  "
                  @copy="handleCopy"
                  @view-profile="emit('view-profile', $event)"
                />
              </template>
            </div>

            <!-- 空状态 -->
            <div
              v-if="messages.length === 0 && !isLoading && !messageLoadFailed"
              class="flex min-h-[calc(100vh-14rem)] flex-col items-center justify-center px-6 text-center"
            >
              <div class="mb-4 flex h-14 w-14 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60">
                <Hash class="h-6 w-6 text-muted-foreground" />
              </div>
              <h3 class="text-base font-semibold tracking-tight">
                {{
                  channelSearchActive ? t('chat.messageSearch.empty') : t('chat.message.emptyTitle', {
                    channel: channel.name
                  })
                }}
              </h3>
              <p v-if="!channelSearchActive" class="mt-1.5 max-w-sm text-sm leading-relaxed text-muted-foreground">
                {{ t('chat.message.emptyDescription') }}
              </p>
            </div>
          </div>
        </ScrollArea>

        <!-- 新消息提示 -->
        <div
          v-if="hasNewMessages && !isAtBottom"
          class="absolute bottom-4 left-1/2 -translate-x-1/2"
        >
          <Button
            size="sm"
            class="h-8 gap-1.5 rounded-full px-3 shadow-md"
            @click="scrollToBottom"
          >
            <ArrowDown class="h-3.5 w-3.5" />
            {{ t('chat.message.newMessages') }}
          </Button>
        </div>
      </div>

      <!-- 输入区域 -->
      <div
        v-if="!channelSearchActive && channelTypingCount"
        class="flex items-center gap-2 px-4 py-1 text-xs text-muted-foreground"
        role="status"
      >
        <span class="inline-flex items-center gap-0.5" aria-hidden="true">
          <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 0ms" />
          <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 150ms" />
          <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 300ms" />
        </span>
        <span>
          {{ channelTypingCount === 1 ? t('chat.channelTyping.one') : t('chat.channelTyping.many', {count:channelTypingCount}) }}
        </span>
      </div>
      <ChatInput
        v-show="!channelSearchActive"
        :key="composerRevision"
        :channel-name="channel.name"
        :reply-to="replyTo"
        :disabled="isComposerDisabled"
        :disabled-reason="composerDisabledReason"
        :members="members"
        :channels="channels"
        :send-message="handleSend"
        @cancel-reply="cancelReply"
        @typing="emit('typing-channel', $event)"
      />
    </div>

    <!-- 成员列表 -->
    <ChatMemberList
      v-if="showMemberList"
      :members="members"
      :can-manage="canManage"
      :current-user-id="currentUserId"
      class="hidden lg:flex"
      @message="openDirectMessage"
      @view-profile="member => emit('view-profile', member.id)"
    />

    <Sheet v-model:open="mobileMemberListOpen">
      <SheetContent :side="narrowSheet ? 'bottom' : 'right'" class="flex w-full flex-col p-0 sm:w-80">
        <SheetHeader class="px-4 py-3">
          <SheetTitle class="text-sm font-semibold tracking-tight">
            {{ t('chat.actions.showMembers') }}
          </SheetTitle>
        </SheetHeader>
        <ChatMemberList
          :members="members"
          :can-manage="canManage"
          :current-user-id="currentUserId"
          class="border-l-0"
          @message="openDirectMessage"
          @view-profile="member => emit('view-profile', member.id)"
        />
      </SheetContent>
    </Sheet>

    <Dialog v-model:open="callDialogOpen">
      <DialogContent class="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {{
              callDialogType === 'voice'
                ? t('chat.calls.voiceTitle')
                : t('chat.calls.videoTitle')
            }}
          </DialogTitle>
          <DialogDescription>
            {{ t('chat.calls.chooseMember') }}
          </DialogDescription>
        </DialogHeader>
        <select v-model="callMemberId" :aria-label="t('chat.calls.member')" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm">
          <option value="">{{ t('chat.calls.member') }}</option>
          <option v-for="member in callMembers" :key="member.id" :value="member.id">
            {{ member.nickname || member.username }}
          </option>
        </select>
        <DialogFooter>
          <Button variant="outline" @click="callDialogOpen = false">
            {{ t('common.cancel') }}
          </Button>
          <Button :disabled="!callMemberId" @click="handleStartCall">
            {{
              callDialogType === 'voice'
                ? t('chat.actions.startVoiceCall')
                : t('chat.actions.startVideoCall')
            }}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <Sheet v-model:open="directMessageOpen">
      <SheetContent :side="narrowSheet ? 'bottom' : 'right'" class="flex w-full flex-col p-0 sm:w-96">
        <div class="border-b border-[var(--divider)] px-5 py-4">
          <div class="flex items-start gap-3 pr-16">
            <button
              type="button"
              class="shrink-0 rounded-full focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
              :disabled="!directMessageTarget"
              @click="
                directMessageTarget &&
                emit('view-profile', directMessageTarget.id)
              "
            >
              <UserAvatar
                v-if="directMessageTarget"
                :src="directMessageTarget.avatar"
                :name="directMessageTarget.nickname"
                :username="directMessageTarget.username"
                :seed="directMessageTarget.id"
                size="md"
              />
            </button>
            <div class="min-w-0 flex-1">
              <div
                v-if="directMessageTarget"
                class="truncate text-base font-semibold tracking-tight"
              >
                {{ directMessageTarget.nickname }}
              </div>
              <div
                v-if="directMessageTarget"
                class="truncate text-xs text-muted-foreground"
              >
                @{{ directMessageTarget.username }}
              </div>
              <div class="mt-1 text-[11px] text-muted-foreground">
                {{ t('chat.directMessage.title') }}
              </div>
            </div>
            <Button v-if="directMessageTarget" type="button" variant="ghost" size="icon" class="h-8 w-8 shrink-0"
              :aria-label="t('chat.actions.startVoiceCall')" @click="emit('start-call',directMessageTarget,'voice')">
              <Phone class="h-4 w-4" />
            </Button>
            <Button v-if="directMessageTarget" type="button" variant="ghost" size="icon" class="h-8 w-8 shrink-0"
              :aria-label="t('chat.actions.startVideoCall')" @click="emit('start-call',directMessageTarget,'video')">
              <Video class="h-4 w-4" />
            </Button>
            <Button v-if="directMessageTarget" type="button" size="icon" variant="ghost" class="h-8 w-8 shrink-0"
              :aria-label="t('chat.actions.searchMessages')" :aria-expanded="showDirectSearch" @click="toggleDirectSearch">
              <Search class="h-4 w-4" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              class="ml-auto h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
              :disabled="!directMessageTarget"
              @click="openDirectMessageStandalone"
            >
              <Maximize2 class="h-4 w-4" />
              <span class="sr-only">{{ t('chat.actions.showMembers') }}</span>
            </Button>
          </div>
        </div>

        <ChatSearchFilters v-if="showDirectSearch && directMessageTarget && currentUserId" :initial-keyword="directSearchKeyword" :senders="[
          { id: currentUserId, label: currentUserName || t('chat.currentUser.name') },
          { id: directMessageTarget.id, label: directMessageTarget.nickname },
        ]" @search="emit('direct-search', $event)" />

        <div v-if="directMessageTarget" class="flex min-h-0 flex-1 flex-col gap-3 p-3 sm:p-4">
          <ScrollArea class="flex-1 rounded-[20px] bg-secondary/35 p-3">
            <div class="flex min-h-full flex-col justify-end gap-3">
              <Button v-if="hasOlderDirectMessages && !isLoadingDirectMessages" variant="outline" size="sm" :disabled="loadingOlderDirectMessages" @click="emit('load-older-direct-messages')">
                {{ t('chat.directMessage.loadOlder') }}
              </Button>
              <div v-if="isLoadingDirectMessages" class="flex min-h-40 items-center justify-center text-sm text-muted-foreground">
                <div class="h-4 w-4 animate-spin rounded-full border-2 border-muted-foreground/30 border-t-primary" />
                <span class="ml-2">{{ t('chat.directMessage.loading') }}</span>
              </div>

              <div v-else-if="!directMessages?.length" class="flex min-h-40 flex-col items-center justify-center px-4 text-center">
                <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60">
                  <Hash class="h-4 w-4 text-muted-foreground" />
                </div>
                <div class="text-sm font-semibold tracking-tight">
                  {{ t(directSearchActive ? 'chat.messageSearch.empty' : 'chat.directMessage.emptyTitle') }}
                </div>
                <div v-if="!directSearchActive" class="mt-1 text-xs leading-relaxed text-muted-foreground">
                  {{ t('chat.directMessage.emptyDescription') }}
                </div>
              </div>

              <div v-else ref="directList" class="flex flex-col">
                <div
                  v-for="(message, index) in directMessages"
                  :key="message.message_id"
                  :data-incoming-direct-message-id="message.author.user_id !== currentUserId ? message.message_id : undefined"
                >
                  <div
                    v-if="shouldShowDmDateSeparator(index)"
                    class="my-2.5 flex justify-center"
                  >
                    <span class="rounded-full bg-background/80 px-3 py-0.5 text-[11px] font-semibold text-muted-foreground">
                      {{ formatDateSeparator(message.created_at) }}
                    </span>
                  </div>
                  <ChatMessage
                    :message="mapV2DirectMessage(message)"
                    :is-own="message.author.user_id === currentUserId"
                    :allow-edit="false"
                    :hide-reply="directSearchActive"
                    :allow-delete="message.can_delete && !message.is_deleted && message.author.user_id === currentUserId"
                    show-avatar
                    :is-first-in-group="isDmFirstInGroup(index)"
                    :is-last-in-group="isDmLastInGroup(index)"
                    @reply="directReplyId = $event.id"
                    @react="(id, emoji) => emit('react-direct-message', id, emoji)"
                    @delete="emit('delete-direct-message', message)"
                    @view-profile="emit('view-profile', $event)"
                  />
                  <p v-if="!directSearchActive && message.message_id === lastSeenOwnDirectMessage" class="px-3 text-right text-xs text-muted-foreground">
                    {{ t('chat.directMessage.read') }}
                  </p>
                </div>
              </div>
            </div>
          </ScrollArea>

          <div
            v-if="!directSearchActive && directTyping"
            class="flex items-center gap-2 px-1 text-xs text-muted-foreground"
            role="status"
          >
            <span class="inline-flex items-center gap-0.5" aria-hidden="true">
              <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 0ms" />
              <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 150ms" />
              <span class="animate-typing-dot size-1.5 rounded-full bg-primary" style="animation-delay: 300ms" />
            </span>
            <span>
              {{ t('chat.directMessage.typing', { user: directMessageTarget.nickname }) }}
            </span>
          </div>
          <ChatInput
            v-show="!directSearchActive"
            :key="directDraftRevision"
            :placeholder="t('chat.directMessage.placeholder', { user: directMessageTarget.nickname })"
            :disabled="isLoadingDirectMessages"
            :reply-to="directReply"
            :send-message="submitDirectMessage"
            @typing="emit('typing-direct', $event)"
            @cancel-reply="directReplyId = null"
          />
        </div>
      </SheetContent>
    </Sheet>

  </div>
</template>
