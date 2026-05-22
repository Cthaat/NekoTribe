<script setup lang="ts">
import { ref, computed, nextTick, watch } from 'vue';
import {
  Smile,
  Paperclip,
  Image as ImageIcon,
  AtSign,
  Hash,
  X,
  Reply,
  Gift,
  FileText
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import AppSendButton from '@/components/app/AppSendButton.vue';
import { Textarea } from '@/components/ui/textarea';
import {
  Popover,
  PopoverContent,
  PopoverTrigger
} from '@/components/ui/popover';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
import { Input } from '@/components/ui/input';
import { ScrollArea } from '@/components/ui/scroll-area';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import type { ChatMessageType } from './ChatMessage.vue';
import type { ChatMember } from './ChatMemberList.vue';
import type { Channel } from './ChatChannelList.vue';
const { t } = useAppLocale();

type TextareaRef =
  | HTMLTextAreaElement
  | { $el?: HTMLTextAreaElement };

const props = defineProps<{
  channelName?: string;
  replyTo?: ChatMessageType | null;
  disabled?: boolean;
  disabledReason?: string;
  members?: ChatMember[];
  channels?: Channel[];
}>();

const emit = defineEmits<{
  (e: 'send', content: string, attachments?: File[]): void;
  (e: 'cancel-reply'): void;
  (e: 'typing'): void;
}>();

const message = ref('');
const textareaRef = ref<TextareaRef | null>(null);
const attachments = ref<File[]>([]);
const isEmojiPickerOpen = ref(false);
const isMentionPickerOpen = ref(false);
const isChannelPickerOpen = ref(false);
const isStickerPickerOpen = ref(false);
const mentionSearch = ref('');
const channelSearch = ref('');

// 常用表情
const emojis = [
  ['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂'],
  ['🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩'],
  ['😘', '😗', '😚', '😙', '🥲', '😋', '😛', '😜'],
  ['🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🤐'],
  ['🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬'],
  ['😮', '😯', '😲', '😳', '🥺', '😦', '😧', '😨'],
  ['👍', '👎', '👏', '🙌', '🤝', '❤️', '🔥', '✨']
];

const stickers = [
  { value: '🎁', labelKey: 'chat.composer.stickers.gift' },
  { value: '🎉', labelKey: 'chat.composer.stickers.party' },
  { value: '✨', labelKey: 'chat.composer.stickers.sparkles' },
  { value: '💡', labelKey: 'chat.composer.stickers.idea' },
  { value: '🚀', labelKey: 'chat.composer.stickers.rocket' },
  { value: '🍵', labelKey: 'chat.composer.stickers.tea' },
  { value: '✅', labelKey: 'chat.composer.stickers.done' },
  { value: '🙏', labelKey: 'chat.composer.stickers.thanks' }
];

// 计算是否可发送
const canSend = computed(() => {
  return (
    props.disabled !== true &&
    (message.value.trim().length > 0 ||
      attachments.value.length > 0)
  );
});

const inputPlaceholder = computed(() => {
  if (props.disabled && props.disabledReason) {
    return props.disabledReason;
  }
  return t('chat.input.placeholder', {
    channel: props.channelName || t('chat.fallbackChannel')
  });
});

const filteredMembers = computed(() => {
  const query = mentionSearch.value.trim().toLowerCase();
  const members = props.members ?? [];
  if (!query) return members.slice(0, 8);
  return members
    .filter(
      member =>
        member.username.toLowerCase().includes(query) ||
        member.nickname.toLowerCase().includes(query)
    )
    .slice(0, 8);
});

const filteredChannels = computed(() => {
  const query = channelSearch.value.trim().toLowerCase();
  const channels = (props.channels ?? []).filter(
    channel =>
      channel.type === 'text' ||
      channel.type === 'announcement'
  );
  if (!query) return channels.slice(0, 8);
  return channels
    .filter(channel =>
      channel.name.toLowerCase().includes(query)
    )
    .slice(0, 8);
});

const getTextareaElement = (): HTMLTextAreaElement | null => {
  const target = textareaRef.value;
  if (!target) return null;
  if (target instanceof HTMLTextAreaElement) return target;
  return target.$el ?? null;
};

const focusTextarea = () => {
  getTextareaElement()?.focus();
};

const insertText = (text: string) => {
  if (props.disabled) return;
  const textarea = getTextareaElement();
  if (!textarea) {
    message.value += text;
    return;
  }

  const start = textarea.selectionStart ?? message.value.length;
  const end = textarea.selectionEnd ?? message.value.length;
  message.value =
    message.value.slice(0, start) +
    text +
    message.value.slice(end);

  nextTick(() => {
    const nextPosition = start + text.length;
    textarea.focus();
    textarea.setSelectionRange(nextPosition, nextPosition);
  });
};

// 发送消息
const handleSend = () => {
  if (!canSend.value || props.disabled) return;

  emit(
    'send',
    message.value.trim(),
    attachments.value.length > 0
      ? [...attachments.value]
      : undefined
  );
  message.value = '';
  attachments.value = [];

  nextTick(() => {
    focusTextarea();
  });
};

// 插入表情
const insertEmoji = (emoji: string) => {
  if (props.disabled) return;
  insertText(emoji);
  isEmojiPickerOpen.value = false;
  focusTextarea();
};

const insertMention = (member: ChatMember) => {
  if (props.disabled) return;
  insertText(`@${member.username} `);
  mentionSearch.value = '';
  isMentionPickerOpen.value = false;
};

const insertChannel = (channel: Channel) => {
  if (props.disabled) return;
  insertText(`#${channel.name} `);
  channelSearch.value = '';
  isChannelPickerOpen.value = false;
};

const insertSticker = (sticker: string) => {
  if (props.disabled) return;
  insertText(`${sticker} `);
  isStickerPickerOpen.value = false;
};

// 处理键盘事件
const handleKeydown = (e: KeyboardEvent) => {
  if (props.disabled) return;
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    handleSend();
  }
};

// 处理输入
const handleInput = () => {
  if (props.disabled) return;
  emit('typing');
};

// 处理文件选择
const handleFileSelect = (e: Event) => {
  const input = e.target as HTMLInputElement;
  if (props.disabled) {
    input.value = '';
    return;
  }
  if (input.files) {
    attachments.value = [
      ...attachments.value,
      ...Array.from(input.files)
    ];
  }
  input.value = '';
};

// 处理图片选择
const handleImageSelect = (e: Event) => {
  const input = e.target as HTMLInputElement;
  if (props.disabled) {
    input.value = '';
    return;
  }
  if (input.files) {
    const imageFiles = Array.from(input.files).filter(f =>
      f.type.startsWith('image/')
    );
    attachments.value = [
      ...attachments.value,
      ...imageFiles
    ];
  }
  input.value = '';
};

// 移除附件
const removeAttachment = (index: number) => {
  attachments.value.splice(index, 1);
};

// 获取文件预览
const getFilePreview = (file: File): string | undefined => {
  if (file.type.startsWith('image/')) {
    return URL.createObjectURL(file);
  }
  return undefined;
};

const formatFileSize = (size: number) => {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
};

// 取消回复
const handleCancelReply = () => {
  emit('cancel-reply');
};

watch(
  () => props.disabled,
  disabled => {
    if (!disabled) return;
    message.value = '';
    attachments.value = [];
    mentionSearch.value = '';
    channelSearch.value = '';
    isEmojiPickerOpen.value = false;
    isMentionPickerOpen.value = false;
    isChannelPickerOpen.value = false;
    isStickerPickerOpen.value = false;
  }
);
</script>

<template>
  <div class="shrink-0 border-t border-border/60 bg-background/60 p-3 backdrop-blur sm:p-4">
    <!-- 回复预览 -->
    <div
      v-if="replyTo"
      class="mb-2 flex items-center gap-2 rounded-md border-l-2 border-primary/40 bg-muted/40 px-2.5 py-1.5 text-xs"
    >
      <Reply class="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
      <div class="min-w-0 flex-1 truncate">
        <span class="text-muted-foreground">
          {{ t('chat.replyingTo') }}
        </span>
        <span class="font-medium text-foreground">
          {{ replyTo.author.nickname }}
        </span>
        <span class="text-muted-foreground">:</span>
        <span class="ml-1 text-muted-foreground">
          {{ replyTo.content }}
        </span>
      </div>
      <button
        type="button"
        class="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
        :aria-label="t('common.cancel')"
        @click="handleCancelReply"
      >
        <X class="h-3.5 w-3.5" />
      </button>
    </div>

    <!-- 附件预览 -->
    <div
      v-if="attachments.length > 0"
      class="mb-2 flex flex-wrap gap-2"
    >
      <div
        v-for="(file, index) in attachments"
        :key="index"
        class="group/att relative"
      >
        <div
          v-if="file.type.startsWith('image/')"
          class="relative h-20 w-20 overflow-hidden rounded-lg border border-border/60"
        >
          <img
            :src="getFilePreview(file)"
            :alt="file.name"
            class="h-full w-full object-cover"
          />
          <button
            type="button"
            class="absolute -right-1.5 -top-1.5 inline-flex h-5 w-5 items-center justify-center rounded-full border border-border bg-background text-muted-foreground shadow-sm transition-all hover:bg-destructive hover:text-destructive-foreground"
            :aria-label="t('common.cancel')"
            @click="removeAttachment(index)"
          >
            <X class="h-3 w-3" />
          </button>
        </div>

        <div
          v-else
          class="relative flex items-center gap-2 rounded-lg border border-border/60 bg-muted/30 px-2.5 py-2 pr-8"
        >
          <div class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background">
            <FileText class="h-3.5 w-3.5 text-muted-foreground" />
          </div>
          <div class="min-w-0">
            <div class="max-w-[140px] truncate text-xs font-medium">
              {{ file.name }}
            </div>
            <div class="text-[10px] tabular-nums text-muted-foreground">
              {{ formatFileSize(file.size) }}
            </div>
          </div>
          <button
            type="button"
            class="absolute -right-1.5 -top-1.5 inline-flex h-5 w-5 items-center justify-center rounded-full border border-border bg-background text-muted-foreground shadow-sm transition-all hover:bg-destructive hover:text-destructive-foreground"
            :aria-label="t('common.cancel')"
            @click="removeAttachment(index)"
          >
            <X class="h-3 w-3" />
          </button>
        </div>
      </div>
    </div>

    <!-- 输入卡片 -->
    <div
      class="rounded-xl border border-border/60 bg-card shadow-xs transition-colors focus-within:border-ring/60 focus-within:ring-2 focus-within:ring-ring/20"
      :class="{ 'opacity-60': disabled }"
    >
      <!-- 文本区 -->
      <Textarea
        ref="textareaRef"
        v-model="message"
        :placeholder="inputPlaceholder"
        :disabled="disabled"
        class="max-h-32 min-h-[2.5rem] resize-none border-0 bg-transparent px-3 py-2.5 text-sm leading-5 shadow-none focus-visible:ring-0"
        rows="1"
        @keydown="handleKeydown"
        @input="handleInput"
      />

      <!-- 工具栏 -->
      <div class="flex items-center gap-1 px-1.5 py-1.5">
        <TooltipProvider>
          <!-- 上传附件 -->
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
                as="label"
                :disabled="disabled"
              >
                <Paperclip class="h-4 w-4" />
                <input
                  type="file"
                  multiple
                  class="hidden"
                  :disabled="disabled"
                  @change="handleFileSelect"
                />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">
              <p>{{ t('chat.actions.uploadAttachment') }}</p>
            </TooltipContent>
          </Tooltip>

          <!-- 上传图片 -->
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
                as="label"
                :disabled="disabled"
              >
                <ImageIcon class="h-4 w-4" />
                <input
                  type="file"
                  accept="image/*"
                  multiple
                  class="hidden"
                  :disabled="disabled"
                  @change="handleImageSelect"
                />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">
              <p>{{ t('chat.actions.uploadImage') }}</p>
            </TooltipContent>
          </Tooltip>

          <!-- 表情 -->
          <Popover v-model:open="isEmojiPickerOpen">
            <Tooltip>
              <TooltipTrigger as-child>
                <PopoverTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
                    :disabled="disabled"
                  >
                    <Smile class="h-4 w-4" />
                  </Button>
                </PopoverTrigger>
              </TooltipTrigger>
              <TooltipContent side="top">
                <p>{{ t('chat.actions.emoji') }}</p>
              </TooltipContent>
            </Tooltip>
            <PopoverContent
              class="w-auto p-2"
              side="top"
              align="start"
            >
              <div class="grid gap-0.5">
                <div
                  v-for="(row, rowIndex) in emojis"
                  :key="rowIndex"
                  class="flex gap-0.5"
                >
                  <button
                    v-for="emoji in row"
                    :key="emoji"
                    type="button"
                    class="inline-flex h-8 w-8 items-center justify-center rounded-md text-lg transition-colors hover:bg-accent"
                    :disabled="disabled"
                    @click="insertEmoji(emoji)"
                  >
                    {{ emoji }}
                  </button>
                </div>
              </div>
            </PopoverContent>
          </Popover>

          <!-- 提及用户 -->
          <Popover v-model:open="isMentionPickerOpen">
            <Tooltip>
              <TooltipTrigger as-child>
                <PopoverTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
                    :disabled="disabled"
                  >
                    <AtSign class="h-4 w-4" />
                  </Button>
                </PopoverTrigger>
              </TooltipTrigger>
              <TooltipContent side="top">
                <p>{{ t('chat.actions.mentionUser') }}</p>
              </TooltipContent>
            </Tooltip>
            <PopoverContent
              class="w-[min(18rem,calc(100vw-1rem))] p-2"
              side="top"
              align="start"
            >
              <div class="space-y-2">
                <Input
                  v-model="mentionSearch"
                  :placeholder="t('chat.composer.searchMembers')"
                  class="h-8 shadow-xs"
                  :disabled="disabled"
                />
                <ScrollArea class="h-64">
                  <div class="space-y-px">
                    <button
                      v-for="member in filteredMembers"
                      :key="member.id"
                      type="button"
                      class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-accent disabled:opacity-50"
                      :disabled="disabled"
                      @click="insertMention(member)"
                    >
                      <Avatar class="h-7 w-7 ring-1 ring-border">
                        <AvatarImage
                          :src="member.avatar"
                          :alt="member.nickname"
                        />
                        <AvatarFallback class="text-[10px]">
                          {{ member.nickname.slice(0, 2) }}
                        </AvatarFallback>
                      </Avatar>
                      <span class="min-w-0 flex-1">
                        <span class="block truncate text-sm font-medium">
                          {{ member.nickname }}
                        </span>
                        <span class="block truncate text-xs text-muted-foreground">
                          @{{ member.username }}
                        </span>
                      </span>
                    </button>
                    <div
                      v-if="filteredMembers.length === 0"
                      class="px-2 py-6 text-center text-xs text-muted-foreground"
                    >
                      {{ t('chat.composer.noMembers') }}
                    </div>
                  </div>
                </ScrollArea>
              </div>
            </PopoverContent>
          </Popover>

          <!-- 频道链接 -->
          <Popover v-model:open="isChannelPickerOpen">
            <Tooltip>
              <TooltipTrigger as-child>
                <PopoverTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
                    :disabled="disabled"
                  >
                    <Hash class="h-4 w-4" />
                  </Button>
                </PopoverTrigger>
              </TooltipTrigger>
              <TooltipContent side="top">
                <p>{{ t('chat.actions.quoteChannel') }}</p>
              </TooltipContent>
            </Tooltip>
            <PopoverContent
              class="w-[min(16rem,calc(100vw-1rem))] p-2"
              side="top"
              align="start"
            >
              <div class="space-y-2">
                <Input
                  v-model="channelSearch"
                  :placeholder="t('chat.composer.searchChannels')"
                  class="h-8 shadow-xs"
                  :disabled="disabled"
                />
                <ScrollArea class="h-64">
                  <div class="space-y-px">
                    <button
                      v-for="channel in filteredChannels"
                      :key="channel.id"
                      type="button"
                      class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-accent disabled:opacity-50"
                      :disabled="disabled"
                      @click="insertChannel(channel)"
                    >
                      <Hash class="h-4 w-4 shrink-0 text-muted-foreground" />
                      <span class="truncate text-sm">
                        {{ channel.name }}
                      </span>
                    </button>
                    <div
                      v-if="filteredChannels.length === 0"
                      class="px-2 py-6 text-center text-xs text-muted-foreground"
                    >
                      {{ t('chat.composer.noChannels') }}
                    </div>
                  </div>
                </ScrollArea>
              </div>
            </PopoverContent>
          </Popover>

          <!-- 礼物/贴纸 -->
          <Popover v-model:open="isStickerPickerOpen">
            <Tooltip>
              <TooltipTrigger as-child>
                <PopoverTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
                    :disabled="disabled"
                  >
                    <Gift class="h-4 w-4" />
                  </Button>
                </PopoverTrigger>
              </TooltipTrigger>
              <TooltipContent side="top">
                <p>{{ t('chat.actions.sendSticker') }}</p>
              </TooltipContent>
            </Tooltip>
            <PopoverContent
              class="w-56 p-2"
              side="top"
              align="start"
            >
              <div class="grid grid-cols-4 gap-1">
                <button
                  v-for="sticker in stickers"
                  :key="sticker.value"
                  type="button"
                  class="flex h-12 flex-col items-center justify-center gap-0.5 rounded-md p-1 transition-colors hover:bg-accent disabled:opacity-50"
                  :disabled="disabled"
                  @click="insertSticker(sticker.value)"
                >
                  <span class="text-lg leading-none">{{ sticker.value }}</span>
                  <span class="text-[10px] leading-none text-muted-foreground">
                    {{ t(sticker.labelKey) }}
                  </span>
                </button>
              </div>
            </PopoverContent>
          </Popover>
        </TooltipProvider>

        <!-- 发送按钮 -->
        <div class="ml-auto flex items-center">
          <AppSendButton
            :aria-label="t('chat.actions.sendMessage')"
            :disabled="!canSend || disabled"
            size="sm"
            class="h-8 rounded-md px-3"
            @click="handleSend"
          >
            <span class="hidden sm:inline">
              {{ t('chat.actions.sendMessage') }}
            </span>
          </AppSendButton>
        </div>
      </div>
    </div>
  </div>
</template>
