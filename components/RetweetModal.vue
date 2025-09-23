<script setup lang="ts">
import { ref, computed } from 'vue';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription
} from '@/components/ui/dialog';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Textarea } from '@/components/ui/textarea';
import { Button } from '@/components/ui/button';

// --- Props & Emits ---

const props = defineProps({
  // 使用 v-model:open 控制对话框的显示和隐藏
  open: {
    type: Boolean,
    default: false
  },
  // 需要被转发的原始推文对象
  tweet: {
    type: Object,
    required: true
  },
  // 从父组件传入，用于禁用按钮，防止重复提交
  isSubmitting: {
    type: Boolean,
    default: false
  }
});

const emit = defineEmits(['update:open', 'submit-retweet']);

// --- 内部状态 ---

// 绑定用户输入的引用/评论内容
const quoteContent = ref('');

// 计算属性，确保 v-model:open 能正常工作
const internalOpen = computed({
  get: () => props.open,
  set: value => emit('update:open', value)
});

// --- 事件处理 ---

function handleRetweet() {
  if (props.isSubmitting) return;

  // 向父组件发送事件，并附带用户的评论内容和原始推文ID
  emit('submit-retweet', {
    content: quoteContent.value,
    originalTweetId: props.tweet.tweetId
  });
}

// 在对话框关闭时清空输入内容，以便下次打开是干净的
watch(internalOpen, isOpen => {
  if (!isOpen) {
    quoteContent.value = '';
  }
});
</script>

<template>
  <Dialog v-model:open="internalOpen">
    <DialogContent class="sm:max-w-[525px]">
      <DialogHeader>
        <DialogTitle>转发推文</DialogTitle>
      </DialogHeader>

      <div class="flex flex-col gap-4 py-4">
        <!-- 文本输入框，用于添加评论 -->
        <Textarea
          v-model="quoteContent"
          placeholder="添加评论..."
          class="min-h-[80px]"
        />

        <!-- 显示被转发的原始推文（简化版预览） -->
        <div class="mt-2 rounded-xl border p-3">
          <div class="flex items-center gap-2">
            <Avatar class="h-6 w-6">
              <AvatarImage
                :src="tweet.avatarUrl"
                :alt="tweet.username"
              />
              <AvatarFallback>{{
                tweet.username
                  ?.substring(0, 2)
                  .toUpperCase()
              }}</AvatarFallback>
            </Avatar>
            <span class="font-bold text-sm">{{
              tweet.displayName
            }}</span>
            <span class="text-muted-foreground text-sm"
              >@{{ tweet.username }}</span
            >
          </div>
          <p
            class="mt-2 text-sm text-muted-foreground line-clamp-3"
          >
            {{ tweet.content }}
          </p>
        </div>
      </div>

      <DialogFooter>
        <Button
          @click="handleRetweet"
          :disabled="isSubmitting"
          class="w-full"
        >
          <!-- 在提交时可以显示加载状态 -->
          <span v-if="!isSubmitting">转发</span>
          <span v-else>正在转发...</span>
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
