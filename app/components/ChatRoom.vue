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
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
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
        class="h-12 border-b flex items-center justify-between px-4 bg-background flex-shrink-0"
      >
        <div class="flex items-center gap-2">
          <Hash class="h-5 w-5 text-muted-foreground" />
          <span class="font-semibold">{{
            channel.name
          }}</span>
          <div class="h-4 w-px bg-border mx-2" />
          <span
            class="text-sm text-muted-foreground truncate max-w-xs"
          >
            {{
              channel.lastMessage ||
              t('chat.channelDescriptionFallback')
            }}
          </span>
        </div>

        <div class="flex items-center gap-1">
          <TooltipProvider>
            <!-- 语音通话 -->
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="sm"
                  class="h-8 w-8 p-0"
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
                  size="sm"
                  class="h-8 w-8 p-0"
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
                      size="sm"
                      class="h-8 w-8 p-0 relative"
                    >
                      <Pin class="h-4 w-4" />
                      <Badge
                        v-if="pinnedMessages?.length"
                        variant="destructive"
                        class="absolute -top-1 -right-1 h-4 min-w-[16px] px-1 text-[10px]"
                      >
                        {{ pinnedMessages.length }}
                      </Badge>
                    </Button>
                  </SheetTrigger>
                </TooltipTrigger>
                <TooltipContent>
                  <p>{{ t('chat.message.pinnedMessages') }}</p>
                </TooltipContent>
              </Tooltip>
              <SheetContent side="right" class="w-80">
                <SheetHeader>
                  <SheetTitle>{{ t('chat.message.pinnedMessages') }}</SheetTitle>
                </SheetHeader>
                <div class="mt-4 space-y-2">
                  <div
                    v-if="!pinnedMessages?.length"
                    class="text-center text-muted-foreground py-8"
                  >
                    {{ t('chat.message.noPinnedMessages') }}
                  </div>
                  <Card
                    v-for="msg in pinnedMessages"
                    :key="msg.id"
                    class="gap-0 bg-muted/50 py-0 shadow-xs"
                  >
                    <CardContent class="p-3">
                      <div
                        class="mb-1 flex items-center gap-2"
                      >
                        <span class="text-sm font-medium">{{
                          msg.author.nickname
                        }}</span>
                        <span
                          class="text-xs text-muted-foreground"
                        >
                          {{
                            new Date(
                              msg.createdAt
                            ).toLocaleDateString()
                          }}
                        </span>
                      </div>
                      <p class="text-sm">{{ msg.content }}</p>
                    </CardContent>
                  </Card>
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
                      size="sm"
                      class="h-8 w-8 p-0"
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
                  <SheetTitle>
                    {{ t('chat.notifications.title') }}
                  </SheetTitle>
                </SheetHeader>
                <div class="mt-6 space-y-4">
                  <Card class="gap-0 py-0">
                    <CardContent
                      class="flex items-center justify-between gap-4 p-3"
                    >
                      <div class="space-y-1">
                        <Label>
                          {{ t('chat.notifications.muteLabel') }}
                        </Label>
                        <p class="text-sm text-muted-foreground">
                          {{ t('chat.notifications.muteDescription') }}
                        </p>
                      </div>
                      <Switch
                        :model-value="channel.isMuted"
                        @update:model-value="emit('toggle-mute')"
                      />
                    </CardContent>
                  </Card>
                </div>
              </SheetContent>
            </Sheet>

            <!-- 搜索 -->
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="sm"
                  class="h-8 w-8 p-0"
                  :class="{ 'bg-muted': showSearch }"
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
                  size="sm"
                  class="h-8 w-8 p-0"
                  :class="{ 'bg-muted': showMemberList }"
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
        class="px-4 py-2 border-b bg-muted/30 flex-shrink-0"
      >
        <div class="relative max-w-md">
          <Search
            class="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground"
          />
          <Input
            v-model="searchQuery"
            :placeholder="t('chat.searchPlaceholder')"
            class="pl-9"
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
              class="flex justify-center py-4"
            >
              <div
                class="animate-spin rounded-full h-6 w-6 border-b-2 border-primary"
              />
            </div>

            <!-- 消息列表 -->
            <div class="py-4">
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
              />
            </div>

            <!-- 空状态 -->
            <div
              v-if="messages.length === 0 && !isLoading"
              class="flex min-h-[calc(100vh-14rem)] flex-col items-center justify-center text-muted-foreground"
            >
              <Hash class="h-16 w-16 mb-4 opacity-50" />
              <h3 class="text-lg font-semibold mb-1">
                {{
                  t('chat.message.emptyTitle', {
                    channel: channel.name
                  })
                }}
              </h3>
              <p class="text-sm">
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
            class="gap-1 shadow-lg"
            @click="scrollToBottom"
          >
            <ArrowDown class="h-4 w-4" />
            {{ t('chat.message.newMessages') }}
          </Button>
        </div>
      </div>

      <!-- 输入区域 -->
      <ChatInput
        :channel-name="channel.name"
        :reply-to="replyTo"
        :disabled="isSending"
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
    />

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
        <div class="border-b px-5 py-4">
          <div class="flex items-start gap-3 pr-16">
            <Avatar class="h-11 w-11 shrink-0 ring-1 ring-border">
              <AvatarImage
                v-if="directMessageTarget"
                :src="directMessageTarget.avatar"
                :alt="directMessageTarget?.nickname"
              />
              <AvatarFallback v-if="directMessageTarget">
                {{ directMessageTarget.nickname.slice(0, 2) }}
              </AvatarFallback>
            </Avatar>
            <div class="min-w-0 flex-1">
              <div
                v-if="directMessageTarget"
                class="truncate text-base font-semibold leading-6"
              >
                {{ directMessageTarget.nickname }}
              </div>
              <div
                v-if="directMessageTarget"
                class="truncate text-sm text-muted-foreground"
              >
                @{{ directMessageTarget.username }}
              </div>
              <div class="mt-1 text-xs text-muted-foreground">
                {{ t('chat.directMessage.title') }}
              </div>
            </div>
            <Button
              variant="ghost"
              size="icon"
              class="ml-auto mt-0.5 h-9 w-9 rounded-full"
              :disabled="!directMessageTarget"
              @click="openDirectMessageStandalone"
            >
              <Maximize2 class="h-4 w-4" />
              <span class="sr-only">展开到主界面</span>
            </Button>
          </div>
        </div>

        <div v-if="directMessageTarget" class="flex min-h-0 flex-1 flex-col px-4 py-4 gap-4">
          <ScrollArea class="flex-1 rounded-2xl border bg-muted/20 p-4 shadow-sm">
            <div class="flex min-h-full flex-col justify-end gap-3">
              <div v-if="isLoadingDirectMessages" class="flex min-h-40 items-center justify-center text-sm text-muted-foreground">
                {{ t('chat.directMessage.loading') }}
              </div>

              <div v-else-if="!directMessages?.length" class="flex min-h-40 flex-col items-center justify-center text-center text-sm text-muted-foreground">
                <div class="font-medium text-foreground">
                  {{ t('chat.directMessage.emptyTitle') }}
                </div>
                <div class="mt-1">
                  {{ t('chat.directMessage.emptyDescription') }}
                </div>
              </div>

              <div v-else class="flex flex-col gap-3">
                <div
                  v-for="message in directMessages"
                  :key="message.message_id"
                  class="flex"
                  :class="{ 'justify-end': message.author.user_id === currentUserId }"
                >
                  <div class="max-w-[84%]">
                    <div
                      class="rounded-2xl px-4 py-3 text-sm leading-6 shadow-sm"
                      :class="message.author.user_id === currentUserId ? 'ml-auto bg-primary text-primary-foreground' : 'bg-background text-foreground border border-border/80'"
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

          <Card class="gap-0 rounded-2xl py-0">
            <CardContent class="p-3">
              <div class="flex items-center gap-3 rounded-full border bg-background/90 px-3 py-2">
              <Input
                v-model="directMessageContent"
                :placeholder="t('chat.directMessage.placeholder', { user: directMessageTarget.nickname })"
                class="h-11 flex-1 border-0 bg-transparent px-1 shadow-none focus-visible:ring-0"
                @keydown="handleDirectMessageKeydown"
              />
              <AppSendButton
                :loading="isSendingDirectMessage"
                :disabled="isLoadingDirectMessages || isSendingDirectMessage || !directMessageContent.trim()"
                class="h-11 shrink-0 rounded-full px-4"
                @click="submitDirectMessage"
              >
                {{ isSendingDirectMessage ? t('common.processing') : t('chat.actions.sendMessage') }}
              </AppSendButton>
              </div>
            </CardContent>
          </Card>
        </div>
      </SheetContent>
    </Sheet>

  </div>
</template>
