<script setup lang="ts">
import { ref, computed } from 'vue';
import type { PropType } from 'vue';
import type { PostVM } from '@/types/posts';
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
import { Card, CardContent } from '@/components/ui/card';
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
    type: Object as PropType<PostVM>,
    required: true
  },
  // 从父组件传入，用于禁用按钮，防止重复提交
  isSubmitting: {
    type: Boolean,
    default: false
  }
});

const emit = defineEmits(['update:open', 'submit-retweet']);
const { t } = useAppLocale();

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
    originalTweetId: props.tweet.id
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
        <DialogTitle>{{ t('post.retweet.title') }}</DialogTitle>
      </DialogHeader>

      <div class="flex flex-col gap-4 py-4">
        <!-- 文本输入框，用于添加评论 -->
        <Textarea
          v-model="quoteContent"
          :placeholder="t('post.retweet.placeholder')"
          class="min-h-[80px]"
        />

        <!-- 显示被转发的原始推文（简化版预览） -->
        <Card class="mt-2 gap-0 py-0">
          <CardContent class="p-3">
            <div class="flex items-center gap-2">
              <Avatar class="h-6 w-6">
                <AvatarImage
                  :src="tweet.author.avatarUrl"
                  :alt="tweet.author.username"
                />
                <AvatarFallback>{{
                  tweet.author.username
                    ?.substring(0, 2)
                    .toUpperCase()
                }}</AvatarFallback>
              </Avatar>
              <span class="text-sm font-bold">{{
                tweet.author.name
              }}</span>
              <span class="text-sm text-muted-foreground"
                >@{{ tweet.author.username }}</span
              >
            </div>
            <p
              class="mt-2 line-clamp-3 text-sm text-muted-foreground"
            >
              {{ tweet.content }}
            </p>
          </CardContent>
        </Card>
      </div>

      <DialogFooter>
        <Button
          @click="handleRetweet"
          :disabled="isSubmitting"
          class="w-full"
        >
          <!-- 在提交时可以显示加载状态 -->
          <span v-if="!isSubmitting">{{ t('post.retweet.submit') }}</span>
          <span v-else>{{ t('post.retweet.submitting') }}</span>
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>


