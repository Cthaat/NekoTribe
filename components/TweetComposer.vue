<script setup lang="ts">
import { ref, computed } from 'vue';
import { Separator } from '@/components/ui/separator';
import { Textarea } from '@/components/ui/textarea';
import { Button } from '@/components/ui/button';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
import {
  ImageUp,
  Send,
  X,
  Reply,
  MessageSquareReply,
  MessageSquareQuote
} from 'lucide-vue-next';

import TweetPreviewCard from './TweetPreviewCard.vue';

interface PreviewTweet {
  tweetId: number;
  author: {
    displayName: string;
    username: string;
    avatarUrl: string;
  };
  content: string;
}

const props = defineProps<{
  replyTo?: PreviewTweet;
  quoteTo?: PreviewTweet;
}>();

// --- 提交信息 ---
const submitForm = ref({
  content: '', // 推文内容
  replyToTweetId: '', // 回复的推文 ID
  retweetOfTweetId: '', // 转发的推文 ID
  quoteTweetId: '', // 引用的推文 ID
  visibility: '', // 可见性（公开、私密等）
  hashtags: '', // 话题标签
  mentions: '', // 提及的用户
  scheduledAt: '', // 定时发布时间
  location: '' // 位置
});

// --- 传递信息 ---

const emit = defineEmits([
  'open-quote-dialog',
  'open-reply-dialog',
  'submit'
]);

// --- 配置项 ---
const MAX_CHARS = 280; // 推文最大字符数

// --- 响应式状态 ---
const tweetContent = ref(''); // 存储推文的文本内容
const mediaFiles = ref<File[]>([]); // 存储用于上传的真实文件对象
const mediaPreviews = ref<string[]>([]); // 存储用于预览的临时本地 URL
const fileInputRef = ref<HTMLInputElement | null>(null); // 用于引用隐藏的文件输入框

// --- 计算属性 ---

const characterCount = computed(
  () => tweetContent.value.length
);
const isTweetDisabled = computed(() => {
  const count = characterCount.value;
  return count === 0 || count > MAX_CHARS;
});

const circumference = 2 * Math.PI * 14; // 2 * π * r (半径为 14)
const progressOffset = computed(() => {
  const progress = Math.min(
    characterCount.value / MAX_CHARS,
    1
  );
  return circumference * (1 - progress);
});

const progressColorClass = computed(() => {
  const count = characterCount.value;
  if (count > MAX_CHARS) return 'text-red-500';
  if (count > MAX_CHARS - 20) return 'text-yellow-500';
  return 'text-white'; // 新风格：正常状态为白色
});

// --- 方法 ---

function handleQuoteClick() {
  // 当按钮被点击时，向父组件发出 'open-quote-dialog' 事件
  emit('open-quote-dialog');
}

function handleReplyClick() {
  // 当按钮被点击时，向父组件发出 'open-reply-dialog' 事件
  emit('open-reply-dialog');
}

function triggerFileInput() {
  fileInputRef.value?.click();
}

function handleFileSelect(event: Event) {
  const target = event.target as HTMLInputElement;
  if (!target.files) return;

  const files = Array.from(target.files);
  const remainingSlots = 4 - mediaFiles.value.length;

  if (files.length > remainingSlots) {
    alert(
      `你最多还能上传 ${remainingSlots > 0 ? ` ${remainingSlots} 个` : '0 个'}文件。`
    );
  }

  const newFiles = files.slice(0, remainingSlots);
  mediaFiles.value.push(...newFiles);
  const newPreviews = newFiles.map(file =>
    URL.createObjectURL(file)
  );
  mediaPreviews.value.push(...newPreviews);

  target.value = '';
}

function removeMedia(index: number) {
  const [removedPreview] = mediaPreviews.value.splice(
    index,
    1
  );
  URL.revokeObjectURL(removedPreview);
  mediaFiles.value.splice(index, 1);
}

async function handleSubmit() {
  if (isTweetDisabled.value) return;

  console.log('提交的推文内容:', tweetContent.value);

  submitForm.value.content = tweetContent.value;
  submitForm.value.visibility = 'public'; // 默认可见性为公开

  if (props.replyTo) {
    submitForm.value.replyToTweetId = String(
      props.replyTo.tweetId
    );
  }
  if (props.quoteTo) {
    submitForm.value.quoteTweetId = String(
      props.quoteTo.tweetId
    );
  }

  // 创建 FormData 对象
  const formData = new FormData();
  // 只添加媒体文件
  mediaFiles.value.forEach(file => {
    formData.append('file', file);
  });
  // TODO: 添加描述字段
  formData.append('altText', '111');
  formData.append('description', '111123');

  emit('submit', submitForm, formData);
}
</script>

<template>
  <!-- 根元素是一个 flex 容器，使其内容能够垂直分布 -->
  <div class="flex flex-col h-full max-w-3xl mx-auto">
    <!-- 编辑器主区域，占据大部分可用空间 -->
    <div class="flex-1 min-h-0 py-2">
      <Textarea
        v-model="tweetContent"
        placeholder="有什么新鲜事？"
        class="w-full h-full bg-transparent text-lg text-gray-200 placeholder:text-gray-500 border-none focus-visible:ring-0 focus-visible:ring-offset-0 p-2 resize-none leading-relaxed tracking-wide"
      />

      <TweetPreviewCard
        v-if="props.replyTo"
        :tweet="props.replyTo"
      />
      <TweetPreviewCard
        v-else-if="props.quoteTo"
        :tweet="props.quoteTo"
      />

      <!-- 媒体预览区 -->
      <div
        v-if="mediaPreviews.length > 0"
        class="mt-4 grid grid-cols-2 sm:grid-cols-4 gap-3"
      >
        <div
          v-for="(src, index) in mediaPreviews"
          :key="src"
          class="relative aspect-square group"
        >
          <img
            :src="src"
            class="w-full h-full object-cover rounded-lg"
            alt="媒体预览"
          />
          <Button
            variant="ghost"
            size="icon"
            class="absolute top-1 right-1 h-7 w-7 rounded-full bg-black/50 hover:bg-black/70 text-white opacity-0 group-hover:opacity-100 transition-opacity"
            @click="removeMedia(index)"
          >
            <X class="h-4 w-4" />
          </Button>
        </div>
      </div>
    </div>

    <!-- 底部操作栏 -->
    <div class="mt-4 py-4">
      <Separator class="bg-gray-800" />
      <div class="flex justify-between items-center pt-4">
        <!-- 左侧功能按钮 -->
        <div class="flex items-center gap-1">
          <TooltipProvider>
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  @click="triggerFileInput"
                >
                  <ImageUp
                    class="h-6 w-6 text-gray-400 hover:text-white transition-colors"
                  />
                </Button>
              </TooltipTrigger>
              <TooltipContent
                class="bg-black text-white border-gray-700"
              >
                <p>添加媒体</p>
              </TooltipContent>
            </Tooltip>

            <!-- TODO: 添加回复和引用功能 -->
            <!--
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  @click="handleReplyClick"
                >
                  <MessageSquareReply
                    class="h-6 w-6 text-gray-400 hover:text-white transition-colors"
                  />
                </Button>
              </TooltipTrigger>
              <TooltipContent
                class="bg-black text-white border-gray-700"
              >
                <p>回复推文</p>
              </TooltipContent>
            </Tooltip>

            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  @click="handleQuoteClick"
                >
                  <MessageSquareQuote
                    class="h-6 w-6 text-gray-400 hover:text-white transition-colors"
                  />
                </Button>
              </TooltipTrigger>
              <TooltipContent
                class="bg-black text-white border-gray-700"
              >
                <p>引用推文</p>
              </TooltipContent>
            </Tooltip> 
            -->
          </TooltipProvider>
        </div>

        <!-- 右侧提交区域 -->
        <div class="flex items-center gap-4">
          <!-- 环形进度条 -->
          <div class="relative h-8 w-8">
            <svg class="h-full w-full" viewBox="0 0 32 32">
              <circle
                cx="16"
                cy="16"
                r="14"
                fill="transparent"
                stroke="currentColor"
                stroke-width="2.5"
                class="text-gray-700"
              />
              <circle
                cx="16"
                cy="16"
                r="14"
                fill="transparent"
                stroke="currentColor"
                stroke-width="2.5"
                :stroke-dasharray="circumference"
                :stroke-dashoffset="progressOffset"
                :class="progressColorClass"
                class="transform -rotate-90 origin-center transition-all duration-300"
              />
            </svg>
            <span
              v-if="characterCount > MAX_CHARS - 21"
              class="absolute inset-0 flex items-center justify-center text-xs font-bold"
              :class="progressColorClass"
            >
              {{ MAX_CHARS - characterCount }}
            </span>
          </div>

          <!-- 提交按钮 -->
          <Button
            @click="handleSubmit"
            :disabled="isTweetDisabled"
            class="font-bold"
          >
            <Send class="h-4 w-4 mr-2" />
            发布
          </Button>
        </div>
      </div>
    </div>

    <!-- 隐藏的文件输入框 -->
    <input
      ref="fileInputRef"
      type="file"
      multiple
      accept="image/*,video/*"
      class="hidden"
      @change="handleFileSelect"
    />
  </div>
</template>
