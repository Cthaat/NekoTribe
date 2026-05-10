<script setup lang="ts">
import {
  ref,
  computed,
  onMounted,
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
  ArrowDown
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import { Switch } from '@/components/ui/switch';
import { Label } from '@/components/ui/label';
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
onMounted(() => {
  scrollToBottom(false);
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
                  <div
                    v-for="msg in pinnedMessages"
                    :key="msg.id"
                    class="p-3 bg-muted rounded-lg"
                  >
                    <div
                      class="flex items-center gap-2 mb-1"
                    >
                      <span class="font-medium text-sm">{{
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
                  <div
                    class="flex items-center justify-between gap-4 rounded-md border p-3"
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
                  </div>
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
      <div
        ref="messagesContainerRef"
        class="relative min-h-0 flex-1 overflow-y-auto"
        @scroll="handleScroll"
      >
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
          class="flex flex-col items-center justify-center h-full text-muted-foreground"
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
      <SheetContent side="right" class="flex w-full flex-col p-6 sm:w-96">
        <SheetHeader>
          <SheetTitle>
            {{ t('chat.directMessage.title') }}
          </SheetTitle>
        </SheetHeader>
        <div
          v-if="directMessageTarget"
          class="mt-6 flex min-h-0 flex-1 flex-col gap-4"
        >
          <div class="flex items-center gap-3 rounded-md border p-3">
            <Avatar class="h-10 w-10">
              <AvatarImage
                :src="directMessageTarget.avatar"
                :alt="directMessageTarget.nickname"
              />
              <AvatarFallback>
                {{ directMessageTarget.nickname.slice(0, 2) }}
              </AvatarFallback>
            </Avatar>
            <div class="min-w-0">
              <div class="truncate font-medium">
                {{ directMessageTarget.nickname }}
              </div>
              <div class="truncate text-sm text-muted-foreground">
                @{{ directMessageTarget.username }}
              </div>
            </div>
          </div>

          <div
            class="min-h-40 flex-1 overflow-y-auto rounded-md border bg-muted/20 p-3"
          >
            <div
              v-if="isLoadingDirectMessages"
              class="flex h-full min-h-40 items-center justify-center text-sm text-muted-foreground"
            >
              {{ t('chat.directMessage.loading') }}
            </div>
            <div
              v-else-if="!directMessages?.length"
              class="flex h-full min-h-40 flex-col items-center justify-center text-center text-sm text-muted-foreground"
            >
              <div class="font-medium text-foreground">
                {{ t('chat.directMessage.emptyTitle') }}
              </div>
              <div class="mt-1">
                {{ t('chat.directMessage.emptyDescription') }}
              </div>
            </div>
            <div v-else class="space-y-3">
              <div
                v-for="message in directMessages"
                :key="message.message_id"
                class="flex"
                :class="{
                  'justify-end':
                    message.author.user_id === currentUserId
                }"
              >
                <div
                  class="max-w-[82%] rounded-md px-3 py-2 text-sm shadow-sm"
                  :class="
                    message.author.user_id === currentUserId
                      ? 'bg-primary text-primary-foreground'
                      : 'bg-background'
                  "
                >
                  <div class="whitespace-pre-wrap break-words">
                    {{ message.content }}
                  </div>
                  <div
                    class="mt-1 text-[11px] opacity-70"
                  >
                    {{
                      new Date(
                        message.created_at
                      ).toLocaleTimeString([], {
                        hour: '2-digit',
                        minute: '2-digit'
                      })
                    }}
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="space-y-3">
            <Textarea
              v-model="directMessageContent"
              :placeholder="
                t('chat.directMessage.placeholder', {
                  user: directMessageTarget.nickname
                })
              "
              class="min-h-24 resize-none"
            />
            <AppSendButton
              class="w-full"
              :loading="isSendingDirectMessage"
              :disabled="
                isLoadingDirectMessages ||
                isSendingDirectMessage ||
                !directMessageContent.trim()
              "
              @click="submitDirectMessage"
            >
              {{
                isSendingDirectMessage
                  ? t('common.processing')
                  : t('chat.actions.sendMessage')
              }}
            </AppSendButton>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  </div>
</template>
