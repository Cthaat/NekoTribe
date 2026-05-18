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
  Gift
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
    message.value.trim().length > 0 ||
    attachments.value.length > 0
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

  // 重新聚焦输入框
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
  <div class="border-t bg-background p-3">
    <!-- 回复预览 -->
    <div
      v-if="replyTo"
      class="flex items-center gap-2 mb-2 p-2 bg-muted rounded-lg text-sm"
    >
      <Reply
        class="h-4 w-4 text-muted-foreground flex-shrink-0"
      />
      <div class="flex-1 min-w-0">
        <span class="text-muted-foreground">{{ t('chat.replyingTo') }} </span>
        <span class="font-medium">{{
          replyTo.author.nickname
        }}</span>
        <span class="text-muted-foreground">: </span>
        <span class="truncate">{{ replyTo.content }}</span>
      </div>
      <Button
        variant="ghost"
        size="sm"
        class="h-6 w-6 p-0"
        @click="handleCancelReply"
      >
        <X class="h-4 w-4" />
      </Button>
    </div>

    <!-- 附件预览 -->
    <div
      v-if="attachments.length > 0"
      class="flex flex-wrap gap-2 mb-2"
    >
      <div
        v-for="(file, index) in attachments"
        :key="index"
        class="relative group"
      >
        <!-- 图片预览 -->
        <div
          v-if="file.type.startsWith('image/')"
          class="relative"
        >
          <img
            :src="getFilePreview(file)"
            :alt="file.name"
            class="h-20 w-20 object-cover rounded-lg"
          />
          <Button
            variant="destructive"
            size="sm"
            class="absolute -top-2 -right-2 h-5 w-5 p-0 rounded-full opacity-0 group-hover:opacity-100 transition-opacity"
            @click="removeAttachment(index)"
          >
            <X class="h-3 w-3" />
          </Button>
        </div>

        <!-- 文件预览 -->
        <div
          v-else
          class="flex items-center gap-2 p-2 bg-muted rounded-lg pr-8"
        >
          <div class="p-2 bg-background rounded">📄</div>
          <div class="text-sm">
            <div class="font-medium truncate max-w-[150px]">
              {{ file.name }}
            </div>
            <div class="text-xs text-muted-foreground">
              {{ (file.size / 1024).toFixed(1) }} KB
            </div>
          </div>
          <Button
            variant="destructive"
            size="sm"
            class="absolute -top-2 -right-2 h-5 w-5 p-0 rounded-full opacity-0 group-hover:opacity-100 transition-opacity"
            @click="removeAttachment(index)"
          >
            <X class="h-3 w-3" />
          </Button>
        </div>
      </div>
    </div>

    <!-- 输入区域 -->
    <div class="flex flex-col gap-2 sm:flex-row sm:items-end">
      <!-- 工具按钮 -->
      <div class="flex h-auto flex-wrap items-center gap-1 sm:h-11 sm:flex-nowrap">
        <TooltipProvider>
          <!-- 上传附件 -->
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="sm"
                :class="[
                  'h-8 w-8 p-0',
                  disabled ? 'pointer-events-none opacity-50' : ''
                ]"
                as="label"
                :disabled="disabled"
              >
                <Paperclip class="h-4 w-4" />
                <Input
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
                size="sm"
                :class="[
                  'h-8 w-8 p-0',
                  disabled ? 'pointer-events-none opacity-50' : ''
                ]"
                as="label"
                :disabled="disabled"
              >
                <ImageIcon class="h-4 w-4" />
                <Input
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
                    size="sm"
                    class="h-8 w-8 p-0"
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
              <div class="grid gap-1">
                <div
                  v-for="(row, rowIndex) in emojis"
                  :key="rowIndex"
                  class="flex gap-1"
                >
                  <Button
                    v-for="emoji in row"
                    :key="emoji"
                    variant="ghost"
                    size="sm"
                    class="h-8 w-8 p-0 text-lg hover:bg-muted"
                    :disabled="disabled"
                    @click="insertEmoji(emoji)"
                  >
                    {{ emoji }}
                  </Button>
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
                    size="sm"
                    class="h-8 w-8 p-0"
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
                  class="h-8"
                  :disabled="disabled"
                />
                <ScrollArea class="h-64">
                  <Button
                    v-for="member in filteredMembers"
                    :key="member.id"
                    variant="ghost"
                    class="h-auto w-full justify-start gap-2 px-2 py-2"
                    :disabled="disabled"
                    @click="insertMention(member)"
                  >
                    <Avatar class="h-7 w-7">
                      <AvatarImage
                        :src="member.avatar"
                        :alt="member.nickname"
                      />
                      <AvatarFallback>
                        {{ member.nickname.slice(0, 2) }}
                      </AvatarFallback>
                    </Avatar>
                    <span class="min-w-0 text-left">
                      <span class="block truncate text-sm">
                        {{ member.nickname }}
                      </span>
                      <span
                        class="block truncate text-xs text-muted-foreground"
                      >
                        @{{ member.username }}
                      </span>
                    </span>
                  </Button>
                  <div
                    v-if="filteredMembers.length === 0"
                    class="px-2 py-6 text-center text-sm text-muted-foreground"
                  >
                    {{ t('chat.composer.noMembers') }}
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
                    size="sm"
                    class="h-8 w-8 p-0"
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
                  class="h-8"
                  :disabled="disabled"
                />
                <ScrollArea class="h-64">
                  <Button
                    v-for="channel in filteredChannels"
                    :key="channel.id"
                    variant="ghost"
                    class="h-9 w-full justify-start gap-2 px-2"
                    :disabled="disabled"
                    @click="insertChannel(channel)"
                  >
                    <Hash class="h-4 w-4 text-muted-foreground" />
                    <span class="truncate text-sm">
                      {{ channel.name }}
                    </span>
                  </Button>
                  <div
                    v-if="filteredChannels.length === 0"
                    class="px-2 py-6 text-center text-sm text-muted-foreground"
                  >
                    {{ t('chat.composer.noChannels') }}
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
                    size="sm"
                    class="h-8 w-8 p-0"
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
                <Button
                  v-for="sticker in stickers"
                  :key="sticker.value"
                  variant="ghost"
                  class="h-12 flex-col gap-1 p-1"
                  :disabled="disabled"
                  @click="insertSticker(sticker.value)"
                >
                  <span class="text-lg">{{ sticker.value }}</span>
                  <span class="text-[10px] leading-none">
                    {{ t(sticker.labelKey) }}
                  </span>
                </Button>
              </div>
            </PopoverContent>
          </Popover>
        </TooltipProvider>
      </div>

      <!-- 输入框 -->
      <div class="relative min-w-0 flex-1">
        <Textarea
          ref="textareaRef"
          v-model="message"
          :placeholder="inputPlaceholder"
          :disabled="disabled"
          class="min-h-11 max-h-32 resize-none px-4 py-2.5 leading-5 rounded-xl bg-card border"
          rows="1"
          @keydown="handleKeydown"
          @input="handleInput"
        />
      </div>

      <!-- 发送按钮 -->
      <div class="flex items-center sm:shrink-0">
        <AppSendButton
          :aria-label="t('chat.actions.sendMessage')"
          :disabled="!canSend || disabled"
          variant="secondary"
          class="h-10 w-full rounded-lg px-4 sm:w-auto"
          @click="handleSend"
        >
          {{ t('chat.actions.sendMessage') }}
        </AppSendButton>
      </div>
    </div>
  </div>
</template>
