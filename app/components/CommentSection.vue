<script setup lang="ts">
import { ref, computed } from 'vue';
import type { PropType } from 'vue';
import type {
  CommentVM,
  NestedCommentVM
} from '@/types/posts';
import { toast } from 'vue-sonner';
import { MessageSquare } from 'lucide-vue-next';
import CommentCard from './CommentCard.vue';
import { Textarea } from '@/components/ui/textarea';
import AppSendButton from '@/components/app/AppSendButton.vue';

const { t } = useAppLocale();

const props = defineProps({
  // Service 层输出的扁平评论 VM 列表
  comments: {
    type: Array as PropType<CommentVM[]>,
    required: true
  },
  // 这些评论所属的文章/帖子的 ID
  postId: {
    type: [String, Number],
    required: true
  }
});

const emit = defineEmits([
  'like-comment',
  'submit-reply',
  'send-reply'
]);

const newCommentContent = ref('');
const isSubmitting = ref(false);
const isCommentInputFocused = ref(false);

/**
 * 将扁平的列表（通过 parentCommentId 关联）转换为嵌套的树状结构。
 * 这是一个非常关键的辅助函数。
 * @param list 扁平的评论数组
 */
function flatToTree(list: CommentVM[]): NestedCommentVM[] {
  const map: Record<number, NestedCommentVM> = {};
  const roots: NestedCommentVM[] = [];

  // 第一次遍历：将所有节点放入 map 中，并初始化 children 数组
  for (const item of list) {
    map[item.id] = { ...item, children: [] };
  }

  // 第二次遍历：将每个节点连接到其父节点上
  for (const item of list) {
    const current = map[item.id];
    if (!current) continue;

    if (item.parentCommentId) {
      // 如果是回复，找到它的父节点，并把自己加到父节点的 children 中
      const parent = map[item.parentCommentId];
      if (parent) {
        parent.children.push(current);
      } else {
        roots.push(current);
      }
    } else {
      // 如果是顶级评论，直接放入 roots 数组
      roots.push(current);
    }
  }
  return roots;
}

// 这个计算属性持有最终用于渲染的、嵌套好的评论树
const nestedComments = computed(() =>
  flatToTree(props.comments)
);

// --- API 调用处理器 ---

async function handleLikeComment({
  commentId,
  action
}: {
  commentId: string | number;
  action: 'likeComment' | 'unlikeComment';
}) {
  toast.success(
    t(
      action === 'likeComment'
        ? 'comment.feedback.liked'
        : 'comment.feedback.unliked',
      { id: Number(commentId) }
    )
  );
  emit('like-comment', commentId, action);
}

async function handleSubmitReply({
  parentCommentId,
  content
}: {
  parentCommentId: string | number;
  content: string;
}) {
  isSubmitting.value = true;
  try {
    toast.success(t('comment.feedback.replySubmitted'));
    emit('submit-reply', parentCommentId, content);
  } catch (err) {
    toast.error(t('comment.feedback.replyFailed'));
  } finally {
    isSubmitting.value = false;
  }
}

async function handleSubmitTweetReply() {
  if (!newCommentContent.value.trim()) return;

  isSubmitting.value = true;
  try {
    toast.success(t('comment.feedback.submitted'));
    emit('send-reply', newCommentContent.value);
    newCommentContent.value = ''; // 清空输入框
  } catch (err) {
    toast.error(t('comment.feedback.replyFailed'));
  } finally {
    isSubmitting.value = false;
  }
}

function handleCommentInputBlur() {
  globalThis.setTimeout(() => {
    isCommentInputFocused.value = false;
  }, 200);
}
</script>

<template>
  <div class="w-full max-w-3xl mx-auto p-6 font-sans">
    <!-- 评论区标题 -->
    <div class="flex items-center gap-3 mb-6">
      <h2
        class="text-2xl font-bold bg-gradient-to-r from-primary to-primary/60 bg-clip-text text-transparent"
      >
        {{ t('comment.title') }}
      </h2>
      <span
        class="text-sm text-muted-foreground bg-muted px-3 py-1 rounded-full"
      >
        {{ t('comment.count', { count: comments.length }) }}
      </span>
    </div>

    <!-- 发表顶级评论的表单 -->
    <div
      class="mb-8 p-4 rounded-xl border-2 transition-all duration-300"
      :class="
        isCommentInputFocused
          ? 'border-primary bg-accent/5 shadow-lg shadow-primary/10'
          : 'border-border bg-card'
      "
    >
      <Textarea
        v-model="newCommentContent"
        :placeholder="t('comment.placeholder')"
        class="mb-2 border-none focus-visible:ring-0 resize-none min-h-[80px] text-base bg-transparent"
        @focus="isCommentInputFocused = true"
        @blur="handleCommentInputBlur"
      />
      <Transition
        enter-active-class="transition-all duration-300 ease-out"
        enter-from-class="opacity-0 transform translate-y-2"
        enter-to-class="opacity-100 transform translate-y-0"
        leave-active-class="transition-all duration-200 ease-in"
        leave-from-class="opacity-100 transform translate-y-0"
        leave-to-class="opacity-0 transform translate-y-2"
      >
        <div
          v-if="isCommentInputFocused"
          class="flex justify-between items-center mt-3"
        >
          <span class="text-xs text-muted-foreground ml-2">
            {{
              t('comment.characterCount', {
                count: newCommentContent.length,
                max: 500
              })
            }}
          </span>
          <AppSendButton
            @click="handleSubmitTweetReply"
            :disabled="
              isSubmitting || !newCommentContent.trim()
            "
            size="sm"
          >
            {{
              isSubmitting
                ? t('comment.submitting')
                : t('comment.submit')
            }}
          </AppSendButton>
        </div>
      </Transition>
    </div>

    <!-- 评论列表的渲染从此开始 -->
    <div v-if="nestedComments.length > 0" class="space-y-3">
      <CommentCard
        v-for="comment in nestedComments"
        :key="comment.id"
        :comment="comment"
        :level="0"
        @like-comment="handleLikeComment"
        @submit-reply="handleSubmitReply"
      />
    </div>
    <div v-else class="text-center py-16 px-4">
      <div
        class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-muted mb-4"
      >
        <MessageSquare
          class="w-8 h-8 text-muted-foreground"
        />
      </div>
      <p class="text-lg font-medium text-foreground mb-2">
        {{ t('comment.emptyTitle') }}
      </p>
      <p class="text-sm text-muted-foreground">
        {{ t('comment.emptyDescription') }}
      </p>
    </div>
  </div>
</template>



