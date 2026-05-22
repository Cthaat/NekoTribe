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
import { Card, CardContent } from '@/components/ui/card';
import { Textarea } from '@/components/ui/textarea';
import AppSendButton from '@/components/app/AppSendButton.vue';
import { Button } from '@/components/ui/button';

const { t } = useAppLocale();

const props = defineProps({
  comments: {
    type: Array as PropType<CommentVM[]>,
    required: true
  },
  postId: {
    type: [String, Number],
    required: true
  },
  enableDelete: {
    type: Boolean,
    default: false
  }
});

const emit = defineEmits([
  'like-comment',
  'submit-reply',
  'send-reply',
  'delete-comment'
]);

const newCommentContent = ref('');
const isSubmitting = ref(false);
const isCommentInputFocused = ref(false);

const MAX_LENGTH = 500;

function flatToTree(list: CommentVM[]): NestedCommentVM[] {
  const map: Record<number, NestedCommentVM> = {};
  const roots: NestedCommentVM[] = [];

  for (const item of list) {
    map[item.id] = { ...item, children: [] };
  }

  for (const item of list) {
    const current = map[item.id];
    if (!current) continue;

    if (item.parentCommentId) {
      const parent = map[item.parentCommentId];
      if (parent) {
        parent.children.push(current);
      } else {
        roots.push(current);
      }
    } else {
      roots.push(current);
    }
  }
  return roots;
}

const nestedComments = computed(() =>
  flatToTree(props.comments)
);

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

function handleDeleteComment(commentId: string | number) {
  emit('delete-comment', commentId);
}

async function handleSubmitTweetReply() {
  if (!newCommentContent.value.trim()) return;

  isSubmitting.value = true;
  try {
    toast.success(t('comment.feedback.submitted'));
    emit('send-reply', newCommentContent.value);
    newCommentContent.value = '';
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
  <div class="mx-auto w-full max-w-3xl px-3 py-6 sm:p-6">
    <div class="mb-5 flex items-center gap-2">
      <h2 class="text-lg font-semibold tracking-tight">
        {{ t('comment.title') }}
      </h2>
      <span
        class="tabular-nums rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-xs font-medium text-muted-foreground"
      >
        {{ comments.length }}
      </span>
    </div>

    <Card
      class="mb-6 gap-0 overflow-hidden border-border/60 py-0 shadow-none transition-colors"
      :class="{ 'border-ring/60 ring-2 ring-ring/20': isCommentInputFocused }"
    >
      <CardContent class="p-3">
        <Textarea
          v-model="newCommentContent"
          :placeholder="t('comment.placeholder')"
          :maxlength="MAX_LENGTH"
          class="min-h-[80px] resize-none border-none bg-transparent p-0 text-sm shadow-none focus-visible:ring-0"
          @focus="isCommentInputFocused = true"
          @blur="handleCommentInputBlur"
        />
        <div
          class="mt-3 flex items-center justify-between gap-2 border-t border-border/40 pt-2"
        >
          <span class="text-xs tabular-nums text-muted-foreground">
            {{ newCommentContent.length }} / {{ MAX_LENGTH }}
          </span>
          <div class="flex items-center gap-2">
            <Button
              v-if="isCommentInputFocused && newCommentContent.length > 0"
              variant="ghost"
              size="sm"
              class="h-8"
              @click="newCommentContent = ''"
            >
              {{ t('common.cancel') }}
            </Button>
            <AppSendButton
              size="sm"
              class="h-8"
              :disabled="isSubmitting || !newCommentContent.trim()"
              @click="handleSubmitTweetReply"
            >
              {{ isSubmitting ? t('comment.submitting') : t('comment.submit') }}
            </AppSendButton>
          </div>
        </div>
      </CardContent>
    </Card>

    <div v-if="nestedComments.length > 0" class="space-y-0.5">
      <CommentCard
        v-for="comment in nestedComments"
        :key="comment.id"
        :comment="comment"
        :level="0"
        :enable-delete="enableDelete"
        @like-comment="handleLikeComment"
        @submit-reply="handleSubmitReply"
        @delete-comment="handleDeleteComment"
      />
    </div>
    <div
      v-else
      class="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/60 bg-muted/10 px-6 py-12 text-center"
    >
      <div
        class="mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <MessageSquare class="h-5 w-5 text-muted-foreground" />
      </div>
      <p class="text-base font-semibold tracking-tight">
        {{ t('comment.emptyTitle') }}
      </p>
      <p class="mt-1.5 max-w-sm text-sm leading-relaxed text-muted-foreground">
        {{ t('comment.emptyDescription') }}
      </p>
    </div>
  </div>
</template>
