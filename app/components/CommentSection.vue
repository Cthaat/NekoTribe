<script setup lang="ts">
import { ref, computed } from 'vue';
import type { PropType } from 'vue';
import type {
  CommentVM,
  NestedCommentVM
} from '@/types/posts';
import { toast } from 'vue-sonner';
import CommentCard from './CommentCard.vue';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import UserAvatar from '@/components/UserAvatar.vue';
import { Textarea } from '@/components/ui/textarea';
import AppSendButton from '@/components/app/AppSendButton.vue';
import { Button } from '@/components/ui/button';
import { usePreferenceStore } from '@/stores/user';

const { t } = useAppLocale();
const preferenceStore = usePreferenceStore();
const viewerAvatar = computed(() => preferenceStore.preferences.user.avatarUrl);
const viewerName = computed(() => preferenceStore.preferences.user.name || preferenceStore.preferences.user.username);
const viewerSeed = computed(() => preferenceStore.preferences.user.id || 1);

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
  },
  pendingLikeIds: {
    type: Object as PropType<ReadonlySet<number>>,
    default: undefined
  },
  submitReply: {
    type: Function as PropType<(parentCommentId: number, content: string) => Promise<boolean>>,
    default: undefined
  },
  submitComment: {
    type: Function as PropType<(content: string) => Promise<boolean>>,
    default: undefined
  },
  allowComment: {
    type: Boolean,
    default: true
  },
  showHeader: {
    type: Boolean,
    default: true
  },
  commentByteLimit: {
    type: Number,
    default: undefined
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
const commentLength = computed(() => props.commentByteLimit === undefined
  ? newCommentContent.value.length
  : new TextEncoder().encode(newCommentContent.value.trim()).length);
const commentLimit = computed(() => props.commentByteLimit ?? MAX_LENGTH);

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
  if (!props.pendingLikeIds) {
    toast.success(
      t(
        action === 'likeComment'
          ? 'comment.feedback.liked'
          : 'comment.feedback.unliked',
        { id: Number(commentId) }
      )
    );
  }
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
  if (!props.allowComment || isSubmitting.value || !newCommentContent.value.trim() ||
      commentLength.value > commentLimit.value) return;

  isSubmitting.value = true;
  try {
    if (props.submitComment) {
      if (!(await props.submitComment(newCommentContent.value))) return;
    } else {
      toast.success(t('comment.feedback.submitted'));
      emit('send-reply', newCommentContent.value);
    }
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
  <div class="w-full min-w-0 space-y-3">
    <div
      v-if="allowComment"
      class="flex items-start gap-3 rounded-[20px] bg-card p-3.5 shadow-[0_1px_3px_rgba(15,23,42,0.03)] transition-all duration-200 dark:shadow-none"
      :class="{ 'ring-1 ring-primary/25': isCommentInputFocused }"
    >
      <UserAvatar
        :src="viewerAvatar"
        :name="viewerName"
        :seed="viewerSeed"
        size="md"
      />
      <div class="min-w-0 flex-1">
        <Textarea
          v-model="newCommentContent"
          :placeholder="t('comment.placeholder')"
          :maxlength="commentByteLimit === undefined ? MAX_LENGTH : undefined"
          :disabled="isSubmitting"
          :rows="isCommentInputFocused || newCommentContent.length > 0 ? 3 : 1"
          class="min-h-[40px] resize-none border-none bg-transparent px-0 py-1.5 text-[15px] leading-[1.6] shadow-none transition-all focus-visible:ring-0"
          @focus="isCommentInputFocused = true"
          @blur="handleCommentInputBlur"
        />
        <div
          v-if="isCommentInputFocused || newCommentContent.length > 0"
          class="mt-2 flex items-center justify-between gap-2 border-t border-[var(--divider)] pt-2.5"
        >
          <span class="text-xs tabular-nums text-[var(--ink-tertiary)]">
            {{ commentLength }} / {{ commentLimit }}
          </span>
          <div class="flex items-center gap-2">
            <Button
              v-if="newCommentContent.length > 0"
              variant="ghost"
              size="sm"
              class="h-8 rounded-full"
              :disabled="isSubmitting"
              @click="newCommentContent = ''"
            >
              {{ t('common.cancel') }}
            </Button>
            <AppSendButton
              size="sm"
              class="h-8 rounded-full px-4 font-semibold"
              :disabled="isSubmitting || !newCommentContent.trim() || commentLength > commentLimit"
              @click="handleSubmitTweetReply"
            >
              {{ isSubmitting ? t('comment.submitting') : t('comment.submit') }}
            </AppSendButton>
          </div>
        </div>
      </div>
    </div>

    <div v-if="showHeader" class="flex items-center justify-between px-1 pt-2 text-[13px] font-semibold text-muted-foreground">
      <span>{{ t('comment.title') }}</span>
      <span v-if="comments.length > 0" class="tabular-nums text-[var(--ink-tertiary)]">{{ comments.length }}</span>
    </div>

    <div v-if="nestedComments.length > 0" class="space-y-2.5">
      <CommentCard
        v-for="comment in nestedComments"
        :key="comment.id"
        :comment="comment"
        :level="0"
        :enable-delete="enableDelete"
        :allow-reply="allowComment"
        :pending-like-ids="pendingLikeIds"
        :submit-reply="submitReply"
        @like-comment="handleLikeComment"
        @submit-reply="handleSubmitReply"
        @delete-comment="handleDeleteComment"
      />
    </div>
    <AppEmptyState
      v-else
      :title="t('comment.emptyTitle')"
      :description="t('comment.emptyDescription')"
      compact
    />
  </div>
</template>
