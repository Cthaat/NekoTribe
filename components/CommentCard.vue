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
    id: props.comment.id,
    action: localIsLiked.value
      ? 'likeComment'
      : 'unlikeComment'
  });
}

function handleSubmitReply() {
  if (!replyContent.value.trim()) return;
  // 发送事件，并附带父评论ID和回复内容
  emit('submit-reply', {
    parentCommentId: props.comment.id,
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
      class="p-3 rounded-md transition-colors hover:bg-muted/50"
    >
      <!-- 评论头部：头像、昵称、时间 -->
      <div class="flex items-center text-sm mb-2">
        <Avatar class="h-6 w-6 mr-2">
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
        class="text-base whitespace-pre-wrap leading-relaxed"
      >
        {{ comment.content }}
      </p>

      <!-- 评论操作：点赞、回复 -->
      <div class="mt-2 flex items-center gap-4">
        <Button
          variant="ghost"
          size="sm"
          class="flex items-center gap-2 text-muted-foreground"
          @click="handleLike"
        >
          <Heart
            class="h-4 w-4"
            :class="{
              'fill-red-500 text-red-500': localIsLiked
            }"
          />
          <span>{{ localLikesCount }}</span>
        </Button>
        <Button
          variant="ghost"
          size="sm"
          class="flex items-center gap-2 text-muted-foreground"
          @click="toggleReplyBox"
        >
          <MessageSquare class="h-4 w-4" />
          <span>回复</span>
        </Button>
      </div>

      <!-- 回复框 (条件渲染) -->
      <div v-if="isReplyBoxOpen" class="mt-3">
        <Textarea
          v-model="replyContent"
          placeholder="写下你的回复..."
          class="mb-2"
        />
        <div class="flex justify-end gap-2">
          <Button variant="ghost" @click="toggleReplyBox"
            >取消</Button
          >
          <Button @click="handleSubmitReply"
            >提交回复</Button
          >
        </div>
      </div>
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
        :key="childComment.id"
        :comment="childComment"
        :level="level + 1"
        @like-comment="$emit('like-comment', $event)"
        @submit-reply="$emit('submit-reply', $event)"
      />
    </div>
  </div>
</template>
