<script setup lang="ts">
import { ref, computed } from 'vue';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Heart, MessageSquare } from 'lucide-vue-next';

// 递归组件需要明确地定义自己的名字，以便在模板中引用
defineOptions({
  name: 'CommentCard'
});

const props = defineProps({
  comment: {
    type: Object,
    required: true
  },
  // 嵌套层级，用于计算缩进
  level: {
    type: Number,
    default: 0
  }
});

const emit = defineEmits(['like-comment', 'submit-reply']);

// --- 用于 UI 交互的本地状态 ---
const isReplyBoxOpen = ref(false);
const replyContent = ref('');
const isReplyInputFocused = ref(false);

// 用于点赞的“乐观更新”，提供即时反馈
const localIsLiked = ref(props.comment.isLikedByUser);
const localLikesCount = ref(props.comment.likesCount);

// --- 计算属性 ---
const formattedDate = computed(() => {
  return new Date(props.comment.createdAt).toLocaleString(
    'zh-CN'
  );
});

// 根据嵌套层级计算缩进的样式
const indentationStyle = computed(() => ({
  // 每层缩进 24px，可以按需调整
  marginLeft: `${props.level * 24}px`
}));

// --- 方法 ---
function toggleReplyBox() {
  isReplyBoxOpen.value = !isReplyBoxOpen.value;
  replyContent.value = ''; // 每次打开/关闭时重置内容
}

function handleLike() {
  // 1. 乐观更新 UI
  localIsLiked.value = !localIsLiked.value;
  localLikesCount.value += localIsLiked.value ? 1 : -1;

  // 2. 发送事件给父组件，让父组件处理 API 调用
  emit('like-comment', {
    commentId: props.comment.commentId,
    action: localIsLiked.value
      ? 'likeComment'
      : 'unlikeComment'
  });
}

function handleSubmitReply() {
  if (!replyContent.value.trim()) return;
  // 发送事件，并附带父评论ID和回复内容
  emit('submit-reply', {
    parentCommentId: props.comment.commentId,
    content: replyContent.value
  });
  // 提交后关闭回复框
  isReplyBoxOpen.value = false;
  replyContent.value = '';
}
</script>

<template>
  <div
    class="relative flex flex-col"
    :style="indentationStyle"
  >
    <!-- 用于连接嵌套评论的垂直线，模仿 Reddit 的外观 -->
    <div
      v-if="level > 0"
      class="absolute -left-3 top-0 h-full w-px bg-border"
      aria-hidden="true"
    ></div>

    <div
      class="p-4 rounded-lg transition-all duration-200 hover:bg-accent/50 border border-transparent hover:border-border hover:shadow-sm"
    >
      <!-- 评论头部：头像、昵称、时间 -->
      <div class="flex items-center text-sm mb-3">
        <Avatar
          class="h-8 w-8 mr-3 ring-2 ring-background shadow-sm"
        >
          <AvatarImage
            :src="comment.avatarUrl"
            :alt="comment.displayName"
          />
          <AvatarFallback>{{
            comment.displayName?.substring(0, 1)
          }}</AvatarFallback>
        </Avatar>
        <span class="font-semibold">{{
          comment.displayName
        }}</span>
        <span class="mx-2 text-muted-foreground">·</span>
        <span class="text-muted-foreground">{{
          formattedDate
        }}</span>
      </div>

      <!-- 评论内容 -->
      <p
        class="text-base whitespace-pre-wrap leading-relaxed text-foreground/90 mb-3"
      >
        {{ comment.content }}
      </p>

      <!-- 评论操作：点赞、回复 -->
      <div class="mt-3 flex items-center gap-2">
        <Button
          variant="ghost"
          size="sm"
          class="flex items-center gap-2 text-muted-foreground hover:text-red-500 transition-colors h-8 px-3"
          @click="handleLike"
        >
          <Heart
            class="h-4 w-4 transition-all duration-200"
            :class="{
              'fill-red-500 text-red-500 scale-110':
                localIsLiked
            }"
          />
          <span class="text-xs font-medium">{{
            localLikesCount
          }}</span>
        </Button>
        <Button
          variant="ghost"
          size="sm"
          class="flex items-center gap-2 text-muted-foreground hover:text-primary transition-colors h-8 px-3"
          @click="toggleReplyBox"
        >
          <MessageSquare class="h-4 w-4" />
          <span class="text-xs font-medium">回复</span>
        </Button>
      </div>

      <!-- 回复框 (条件渲染) -->
      <Transition
        enter-active-class="transition-all duration-300 ease-out"
        enter-from-class="opacity-0 transform -translate-y-2"
        enter-to-class="opacity-100 transform translate-y-0"
        leave-active-class="transition-all duration-200 ease-in"
        leave-from-class="opacity-100 transform translate-y-0"
        leave-to-class="opacity-0 transform -translate-y-2"
      >
        <div
          v-if="isReplyBoxOpen"
          class="mt-4 p-3 rounded-lg border-2 transition-all duration-300"
          :class="
            isReplyInputFocused
              ? 'border-primary bg-accent/5'
              : 'border-border bg-muted/30'
          "
        >
          <Textarea
            v-model="replyContent"
            placeholder="写下你的回复..."
            class="mb-2 border-none focus-visible:ring-0 resize-none min-h-[60px] bg-transparent"
            @focus="isReplyInputFocused = true"
            @blur="
              setTimeout(
                () => (isReplyInputFocused = false),
                200
              )
            "
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
              v-if="isReplyInputFocused"
              class="flex justify-end gap-2 mt-2"
            >
              <Button
                variant="ghost"
                size="sm"
                @click="toggleReplyBox"
                >取消</Button
              >
              <Button
                size="sm"
                @click="handleSubmitReply"
                :disabled="!replyContent.trim()"
                >提交回复</Button
              >
            </div>
          </Transition>
        </div>
      </Transition>
    </div>

    <!-- 
      如果这条评论有子评论 (children)，就为每个子评论渲染一个 CommentCard。
    -->
    <div
      v-if="comment.children && comment.children.length > 0"
      class="mt-1"
    >
      <CommentCard
        v-for="childComment in comment.children"
        :key="childComment.commentId"
        :comment="childComment"
        :level="level + 1"
        @like-comment="$emit('like-comment', $event)"
        @submit-reply="$emit('submit-reply', $event)"
      />
    </div>
  </div>
</template>
