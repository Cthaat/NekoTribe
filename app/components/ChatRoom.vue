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
  PanelRightClose,
  PanelRightOpen,
  ArrowDown,
  Maximize2
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Switch } from '@/components/ui/switch';
import { Label } from '@/components/ui/label';
import { ScrollArea } from '@/components/ui/scroll-area';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
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
import ChatMessage from './ChatMessage.vue';
import ChatInput from './ChatInput.vue';
import ChatMemberList from './ChatMemberList.vue';
import AppSendButton from '@/components/app/AppSendButton.vue';
import type { ChatMessageType } from './ChatMessage.vue';
import type { ChatMember } from './ChatMemberList.vue';
import type { Channel } from './ChatChannelList.vue';
import type { V2DirectMessage } from '@/types/v2';
import { toast } from 'vue-sonner';
const { t } = useAppLocale();

const props = defineProps<{
  channel: Channel;
  messages: ChatMessageType[];
  members: ChatMember[];
  pinnedMessages?: ChatMessageType[];
  canManage?: boolean;
  isLoading?: boolean;
  isSending?: boolean;
  currentUserId?: number;
  directMessages?: V2DirectMessage[];
  isLoadingDirectMessages?: boolean;
  isSendingDirectMessage?: boolean;
  channels?: Channel[];
}>();

const emit = defineEmits<{
  (
    e: 'send',
    content: string,
    attachments?: File[],
    replyToMessageId?: number
  ): void;
  (e: 'load-more'): void;
  (e: 'react', messageId: number, emoji: string): void;
  (e: 'reply', message: ChatMessageType): void;
  (e: 'edit', message: ChatMessageType): void;
  (e: 'delete', messageId: number): void;
  (e: 'pin', messageId: number): void;
  (e: 'toggle-mute'): void;
  (e: 'search', query: string): void;
  (e: 'view-profile', userId: number): void;
  (e: 'open-direct-message', member: ChatMember): void;
  (e: 'open-direct-message-standalone', member: ChatMember): void;
  (
    e: 'send-direct-message',
    targetUserId: number,
    content: string
  ): void;
}>();

// 状态
const showMemberList = ref(true);
const mobileMemberListOpen = ref(false);
const showPinnedMessages = ref(false);
const showSearch = ref(false);
const notificationSettingsOpen = ref(false);
const callDialogOpen = ref(false);
const callDialogType = ref<'voice' | 'video'>('voice');
const directMessageOpen = ref(false);
const directMessageTarget = ref<ChatMember | null>(null);
const directMessageContent = ref('');
const searchQuery = ref('');
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

  return false;
};

// 是否显示头像
const shouldShowAvatar = (index: number) => {
  return isFirstInGroup(index);
};

// 是否是自己的消息
const isOwnMessage = (message: ChatMessageType) => {
  return (
    props.currentUserId !== undefined &&
    message.author.id === props.currentUserId
  );
};

const openCallDialog = (type: 'voice' | 'video') => {
  callDialogType.value = type;
  callDialogOpen.value = true;
};

const handleStartCall = () => {
  toast.info(
    callDialogType.value === 'voice'
      ? t('chat.feedback.voiceCallUnavailable')
      : t('chat.feedback.videoCallUnavailable')
  );
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
  directMessageContent.value = '';
  directMessageOpen.value = true;
  emit('open-direct-message', member);
};

const openDirectMessageStandalone = () => {
  if (!directMessageTarget.value) return;
  emit('open-direct-message-standalone', directMessageTarget.value);
};

const handleDirectMessageKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    submitDirectMessage();
  }
};

const submitDirectMessage = () => {
  const target = directMessageTarget.value;
  const content = directMessageContent.value.trim();
  if (!target || !content) return;
  emit('send-direct-message', target.id, content);
  directMessageContent.value = '';
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
const handleSend = (
  content: string,
  attachments?: File[]
) => {
  if (!canSendInChannel.value) return;
  emit('send', content, attachments, replyTo.value?.id);
  replyTo.value = null;
  scrollToBottom();
};

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
        class="flex h-12 shrink-0 items-center justify-between gap-2 border-b border-border/60 bg-background/60 px-3 backdrop-blur sm:px-4"
      >
        <div class="flex min-w-0 items-center gap-2">
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
                  class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
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
                  class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
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
              <SheetContent side="right" class="w-full sm:w-80">
                <SheetHeader>
                  <SheetTitle class="text-base font-semibold tracking-tight">
                    {{ t('chat.message.pinnedMessages') }}
                  </SheetTitle>
                </SheetHeader>
                <div class="mt-4 space-y-2 px-2">
                  <div
                    v-if="!pinnedMessages?.length"
                    class="mx-auto flex max-w-xs flex-col items-center justify-center rounded-xl border border-dashed border-border/60 bg-muted/10 px-4 py-8 text-center"
                  >
                    <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60">
                      <Pin class="h-4 w-4 text-muted-foreground" />
                    </div>
                    <p class="text-xs text-muted-foreground">
                      {{ t('chat.message.noPinnedMessages') }}
                    </p>
                  </div>
                  <div
                    v-for="msg in pinnedMessages"
                    :key="msg.id"
                    class="rounded-lg border border-border/60 bg-card p-3 transition-colors hover:border-border hover:bg-muted/20"
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
                      class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
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
              <SheetContent side="right" class="w-full p-6 sm:w-80">
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
                  @click="showSearch = !showSearch"
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
                  class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground lg:hidden"
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
                  class="hidden h-8 w-8 rounded-md text-muted-foreground hover:text-foreground lg:inline-flex"
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
      <div
        v-if="showSearch"
        class="shrink-0 border-b border-border/60 bg-muted/20 px-3 py-2 sm:px-4"
      >
        <div class="relative max-w-md">
          <Search
            class="pointer-events-none absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground"
          />
          <Input
            v-model="searchQuery"
            :placeholder="t('chat.searchPlaceholder')"
            class="h-9 pl-9 shadow-xs"
            @input="emit('search', searchQuery)"
          />
        </div>
      </div>

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

            <!-- 消息列表 -->
            <div class="py-3">
              <ChatMessage
                v-for="(message, index) in messages"
                :key="message.id"
                :message="message"
                :is-own="isOwnMessage(message)"
                :show-avatar="shouldShowAvatar(index)"
                :is-first-in-group="isFirstInGroup(index)"
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
            </div>

            <!-- 空状态 -->
            <div
              v-if="messages.length === 0 && !isLoading"
              class="flex min-h-[calc(100vh-14rem)] flex-col items-center justify-center px-6 text-center"
            >
              <div class="mb-4 flex h-14 w-14 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60">
                <Hash class="h-6 w-6 text-muted-foreground" />
              </div>
              <h3 class="text-base font-semibold tracking-tight">
                {{
                  t('chat.message.emptyTitle', {
                    channel: channel.name
                  })
                }}
              </h3>
              <p class="mt-1.5 max-w-sm text-sm leading-relaxed text-muted-foreground">
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
      <ChatInput
        :channel-name="channel.name"
        :reply-to="replyTo"
        :disabled="isComposerDisabled"
        :disabled-reason="composerDisabledReason"
        :members="members"
        :channels="channels"
        @send="handleSend"
        @cancel-reply="cancelReply"
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
      <SheetContent side="right" class="flex w-full flex-col p-0 sm:w-80">
        <SheetHeader class="border-b border-border/60 px-4 py-3">
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
            {{
              callDialogType === 'voice'
                ? t('chat.calls.voiceDescription')
                : t('chat.calls.videoDescription')
            }}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" @click="callDialogOpen = false">
            {{ t('common.cancel') }}
          </Button>
          <Button @click="handleStartCall">
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
      <SheetContent side="right" class="flex w-full flex-col p-0 sm:w-96">
        <div class="border-b border-border/60 bg-background/60 px-5 py-4 backdrop-blur">
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
              <Avatar class="h-11 w-11 ring-1 ring-border">
                <AvatarImage
                  v-if="directMessageTarget"
                  :src="directMessageTarget.avatar"
                  :alt="directMessageTarget?.nickname"
                />
                <AvatarFallback v-if="directMessageTarget" class="text-sm font-medium">
                  {{ directMessageTarget.nickname.slice(0, 2) }}
                </AvatarFallback>
              </Avatar>
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

        <div v-if="directMessageTarget" class="flex min-h-0 flex-1 flex-col gap-3 p-4">
          <ScrollArea class="flex-1 rounded-xl border border-border/60 bg-muted/20 p-3">
            <div class="flex min-h-full flex-col justify-end gap-3">
              <div v-if="isLoadingDirectMessages" class="flex min-h-40 items-center justify-center text-sm text-muted-foreground">
                <div class="h-4 w-4 animate-spin rounded-full border-2 border-muted-foreground/30 border-t-primary" />
                <span class="ml-2">{{ t('chat.directMessage.loading') }}</span>
              </div>

              <div v-else-if="!directMessages?.length" class="flex min-h-40 flex-col items-center justify-center px-4 text-center">
                <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60">
                  <Hash class="h-4 w-4 text-muted-foreground" />
                </div>
                <div class="text-sm font-semibold tracking-tight">
                  {{ t('chat.directMessage.emptyTitle') }}
                </div>
                <div class="mt-1 text-xs leading-relaxed text-muted-foreground">
                  {{ t('chat.directMessage.emptyDescription') }}
                </div>
              </div>

              <div v-else class="flex flex-col gap-2.5">
                <div
                  v-for="message in directMessages"
                  :key="message.message_id"
                  class="flex"
                  :class="{ 'justify-end': message.author.user_id === currentUserId }"
                >
                  <div class="max-w-[84%] min-w-0">
                    <div
                      class="rounded-2xl px-3.5 py-2 text-sm leading-relaxed shadow-xs"
                      :class="
                        message.author.user_id === currentUserId
                          ? 'rounded-br-md bg-primary text-primary-foreground'
                          : 'rounded-bl-md border border-border/60 bg-card text-foreground'
                      "
                    >
                      <div class="whitespace-pre-wrap break-words">
                        {{ message.content }}
                      </div>
                    </div>
                    <div
                      class="mt-1 px-1 text-[10px] tabular-nums text-muted-foreground"
                      :class="message.author.user_id === currentUserId ? 'text-right' : 'text-left'"
                    >
                      {{ new Date(message.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </ScrollArea>

          <div class="rounded-xl border border-border/60 bg-card shadow-xs transition-colors focus-within:border-ring/60 focus-within:ring-2 focus-within:ring-ring/20">
            <div class="flex items-center gap-2 p-1.5">
              <Input
                v-model="directMessageContent"
                :placeholder="t('chat.directMessage.placeholder', { user: directMessageTarget.nickname })"
                class="h-9 min-w-0 flex-1 border-0 bg-transparent shadow-none focus-visible:ring-0"
                @keydown="handleDirectMessageKeydown"
              />
              <AppSendButton
                :loading="isSendingDirectMessage"
                :disabled="isLoadingDirectMessages || isSendingDirectMessage || !directMessageContent.trim()"
                size="sm"
                class="h-8 shrink-0 rounded-md px-3"
                @click="submitDirectMessage"
              >
                <span class="hidden sm:inline">
                  {{ isSendingDirectMessage ? t('common.processing') : t('chat.actions.sendMessage') }}
                </span>
              </AppSendButton>
            </div>
          </div>
        </div>
      </SheetContent>
    </Sheet>

  </div>
</template>
