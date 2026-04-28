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
  Users,
  Pin,
  Bell,
  BellOff,
  Settings,
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
import ChatMessage from './ChatMessage.vue';
import ChatInput from './ChatInput.vue';
import ChatMemberList from './ChatMemberList.vue';
import type { ChatMessageType } from './ChatMessage.vue';
import type { ChatMember } from './ChatMemberList.vue';
import type { Channel } from './ChatChannelList.vue';
import { toast } from 'vue-sonner';
const { t } = useAppLocale();

const props = defineProps<{
  channel: Channel;
  messages: ChatMessageType[];
  members: ChatMember[];
  pinnedMessages?: ChatMessageType[];
  canManage?: boolean;
  isLoading?: boolean;
}>();

const emit = defineEmits<{
  (e: 'send', content: string, attachments?: File[]): void;
  (e: 'load-more'): void;
  (e: 'react', messageId: number, emoji: string): void;
  (e: 'reply', message: ChatMessageType): void;
  (e: 'edit', message: ChatMessageType): void;
  (e: 'delete', messageId: number): void;
  (e: 'pin', messageId: number): void;
  (e: 'toggle-mute'): void;
  (e: 'search', query: string): void;
}>();

// 状态
const showMemberList = ref(true);
const showPinnedMessages = ref(false);
const showSearch = ref(false);
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
  // 这里假设当前用户 ID 为 1
  return message.author.id === 1;
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
  emit('send', content, attachments);
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
  <div class="flex h-full">
    <!-- 主聊天区域 -->
    <div class="flex-1 flex flex-col min-w-0">
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
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="sm"
                  class="h-8 w-8 p-0"
                  @click="emit('toggle-mute')"
                >
                  <component
                    :is="channel.isMuted ? BellOff : Bell"
                    class="h-4 w-4"
                  />
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                <p>
                  {{
                    channel.isMuted
                      ? t('chat.actions.unmuteChannel')
                      : t('chat.actions.muteChannel')
                  }}
                </p>
              </TooltipContent>
            </Tooltip>

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
        class="flex-1 overflow-y-auto relative"
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
        @send="handleSend"
        @cancel-reply="cancelReply"
      />
    </div>

    <!-- 成员列表 -->
    <ChatMemberList
      v-if="showMemberList"
      :members="members"
      :can-manage="canManage"
      class="hidden lg:flex"
    />
  </div>
</template>
