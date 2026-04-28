<script setup lang="ts">
import { ref, computed, nextTick } from 'vue';
import {
  Send,
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
import type { ChatMessageType } from './ChatMessage.vue';
const { t } = useAppLocale();

const props = defineProps<{
  channelName?: string;
  replyTo?: ChatMessageType | null;
  disabled?: boolean;
}>();

const emit = defineEmits<{
  (e: 'send', content: string, attachments?: File[]): void;
  (e: 'cancel-reply'): void;
  (e: 'typing'): void;
}>();

const message = ref('');
const textareaRef = ref<HTMLTextAreaElement | null>(null);
const attachments = ref<File[]>([]);
const isEmojiPickerOpen = ref(false);

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

// 计算是否可发送
const canSend = computed(() => {
  return (
    message.value.trim().length > 0 ||
    attachments.value.length > 0
  );
});

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
    textareaRef.value?.focus();
  });
};

// 插入表情
const insertEmoji = (emoji: string) => {
  message.value += emoji;
  isEmojiPickerOpen.value = false;
  textareaRef.value?.focus();
};

// 处理键盘事件
const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    handleSend();
  }
};

// 处理输入
const handleInput = () => {
  emit('typing');
};

// 处理文件选择
const handleFileSelect = (e: Event) => {
  const input = e.target as HTMLInputElement;
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
</script>

<template>
  <div class="border-t bg-background p-4">
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
    <div class="flex items-end gap-2">
      <!-- 工具按钮 -->
      <div class="flex items-center gap-1 pb-2">
        <TooltipProvider>
          <!-- 上传附件 -->
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
                as="label"
              >
                <Paperclip class="h-4 w-4" />
                <input
                  type="file"
                  multiple
                  class="hidden"
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
                class="h-8 w-8 p-0"
                as="label"
              >
                <ImageIcon class="h-4 w-4" />
                <input
                  type="file"
                  accept="image/*"
                  multiple
                  class="hidden"
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
                    @click="insertEmoji(emoji)"
                  >
                    {{ emoji }}
                  </Button>
                </div>
              </div>
            </PopoverContent>
          </Popover>

          <!-- 提及用户 -->
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
              >
                <AtSign class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">
              <p>{{ t('chat.actions.mentionUser') }}</p>
            </TooltipContent>
          </Tooltip>

          <!-- 频道链接 -->
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
              >
                <Hash class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">
              <p>{{ t('chat.actions.quoteChannel') }}</p>
            </TooltipContent>
          </Tooltip>

          <!-- 礼物/贴纸 -->
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="sm"
                class="h-8 w-8 p-0"
              >
                <Gift class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">
              <p>{{ t('chat.actions.sendSticker') }}</p>
            </TooltipContent>
          </Tooltip>
        </TooltipProvider>
      </div>

      <!-- 输入框 -->
      <div class="flex-1 relative">
        <Textarea
          ref="textareaRef"
          v-model="message"
          :placeholder="
            t('chat.input.placeholder', {
              channel: channelName || t('chat.fallbackChannel')
            })
          "
          :disabled="disabled"
          class="min-h-[44px] max-h-32 resize-none pr-12"
          rows="1"
          @keydown="handleKeydown"
          @input="handleInput"
        />
      </div>

      <!-- 发送按钮 -->
      <div class="pb-2">
        <Button
          size="sm"
          class="h-8 w-8 p-0"
          :disabled="!canSend || disabled"
          @click="handleSend"
        >
          <Send class="h-4 w-4" />
        </Button>
      </div>
    </div>
  </div>
</template>
