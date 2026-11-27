<script setup lang="ts">
import { ref, computed } from 'vue';
import type { PropType } from 'vue';
import type { NestedCommentVM } from '@/types/posts';
import UserAvatar from '@/components/UserAvatar.vue';
import LikeButton from '@/components/motion/LikeButton.vue';
import { formatFullTime, formatRelativeTime } from '@/utils/relativeTime';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import AppSendButton from '@/components/app/AppSendButton.vue';
import { MessageSquare, Trash2 } from 'lucide-vue-next';

const { t, locale } = useAppLocale();

defineOptions({
  name: 'CommentCard'
});

const props = defineProps({
  comment: {
    type: Object as PropType<NestedCommentVM>,
    required: true
  },
  level: {
    type: Number,
    default: 0
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
  allowReply: {
    type: Boolean,
    default: true
  }
});

const emit = defineEmits([
  'like-comment',
  'submit-reply',
  'delete-comment'
]);

const isReplyBoxOpen = ref(false);
const replyContent = ref('');
const isReplyInputFocused = ref(false);
const replyPending = ref(false);

const localIsLiked = ref(props.comment.viewer.hasLiked);
const localLikesCount = ref(props.comment.counts.likes);
const isLiked = computed(() =>
  props.pendingLikeIds ? props.comment.viewer.hasLiked : localIsLiked.value
);
const likesCount = computed(() =>
  props.pendingLikeIds ? props.comment.counts.likes : localLikesCount.value
);
const likePending = computed(() =>
  props.pendingLikeIds?.has(props.comment.id) ?? false
);

const formattedDate = computed(() => formatFullTime(props.comment.createdAt, locale.value));
const relativeDate = computed(() => formatRelativeTime(props.comment.createdAt, locale.value));

const indentationStyle = computed(() => ({
  paddingLeft: `${Math.min(props.level, 4) * 24}px`
}));

const fallbackInitial = computed(() => {
  const source =
    props.comment.author.name || props.comment.author.username || '?';
  return source.slice(0, 1).toUpperCase();
});

function toggleReplyBox() {
  if (replyPending.value) return;
  isReplyBoxOpen.value = !isReplyBoxOpen.value;
  replyContent.value = '';
}

function handleLike() {
  if (likePending.value) return;
  const liked = !isLiked.value;
  if (!props.pendingLikeIds) {
    localIsLiked.value = liked;
    localLikesCount.value += liked ? 1 : -1;
  }

  emit('like-comment', {
    commentId: props.comment.id,
    action: liked ? 'likeComment' : 'unlikeComment'
  });
}

async function handleSubmitReply() {
  if (!props.allowReply || replyPending.value || !replyContent.value.trim()) return;
  if (props.submitReply) {
    replyPending.value = true;
    try {
      if (!(await props.submitReply(props.comment.id, replyContent.value))) return;
    } finally {
      replyPending.value = false;
    }
  } else {
    emit('submit-reply', {
      parentCommentId: props.comment.id,
      content: replyContent.value
    });
  }
  isReplyBoxOpen.value = false;
  replyContent.value = '';
}

function handleDelete() {
  emit('delete-comment', props.comment.id);
}

function handleReplyBlur() {
  globalThis.setTimeout(() => {
    isReplyInputFocused.value = false;
  }, 200);
}
</script>

<template>
  <div
    :id="`comment-${comment.id}`"
    class="relative flex min-w-0 flex-col"
    :class="level === 0 ? 'overflow-hidden rounded-[20px] bg-card shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none' : ''"
    :style="indentationStyle"
  >
    <div
      v-if="level > 0"
      class="pointer-events-none absolute -left-3 top-2 bottom-2 w-0.5 rounded-full bg-accent"
      aria-hidden="true"
    />

    <div
      class="group/comment min-w-0 px-4 py-3.5 transition-colors duration-150"
    >
      <div class="flex min-w-0 items-start gap-3">
        <div class="flex shrink-0 flex-col items-center self-stretch">
          <UserAvatar
            :src="comment.author.avatarUrl"
            :name="comment.author.name"
            :username="comment.author.username"
            :seed="comment.author.id"
            size="sm"
          />
          <div
            v-if="comment.children && comment.children.length > 0"
            class="mt-1.5 w-0.5 flex-1 rounded-full bg-accent"
            aria-hidden="true"
          />
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex min-w-0 flex-wrap items-baseline gap-x-1.5 gap-y-0.5 text-sm">
            <span class="truncate font-semibold text-foreground">
              {{ comment.author.name }}
            </span>
            <span class="truncate text-xs text-[var(--ink-tertiary)]">
              @{{ comment.author.username }}
            </span>
            <span class="text-xs text-[var(--ink-tertiary)]">·</span>
            <time
              :datetime="comment.createdAt"
              :title="formattedDate"
              class="text-xs text-[var(--ink-tertiary)]"
            >
              {{ relativeDate }}
            </time>
          </div>

          <p
            class="mt-1 whitespace-pre-wrap break-words text-[15px] leading-[1.62] text-foreground"
          >
            {{ comment.content }}
          </p>

          <div class="mt-1.5 -ml-1.5 flex items-center gap-2">
            <LikeButton
              :liked="isLiked"
              :count="likesCount"
              :disabled="likePending"
              icon-class="size-4"
              @toggle="handleLike"
            />
            <Button
              v-if="allowReply"
              variant="ghost"
                size="icon"
                class="size-8 text-muted-foreground hover:text-foreground"
                :aria-label="t('comment.reply')"
                :title="t('comment.reply')"
                :aria-expanded="isReplyBoxOpen"
                :disabled="replyPending"
              @click="toggleReplyBox"
            >
              <MessageSquare class="h-3.5 w-3.5" />
            </Button>
            <Button
              v-if="enableDelete && comment.viewer.canDelete"
              variant="ghost"
                size="icon"
                class="size-8 text-muted-foreground hover:text-destructive"
                :aria-label="t('comment.delete')"
                :title="t('comment.delete')"
              @click="handleDelete"
            >
              <Trash2 class="h-3.5 w-3.5" />
            </Button>
          </div>

          <Transition
            enter-active-class="transition duration-200 ease-out"
            enter-from-class="opacity-0 -translate-y-1"
            enter-to-class="opacity-100 translate-y-0"
            leave-active-class="transition duration-150 ease-in"
            leave-from-class="opacity-100 translate-y-0"
            leave-to-class="opacity-0 -translate-y-1"
          >
            <div
              v-if="allowReply && isReplyBoxOpen"
              class="mt-2.5 rounded-2xl bg-secondary p-3 transition-colors"
              :class="{ 'ring-1 ring-primary/25': isReplyInputFocused }"
            >
              <Textarea
                v-model="replyContent"
                :disabled="replyPending"
                :placeholder="t('comment.replyPlaceholder')"
                class="min-h-[60px] resize-none border-none bg-transparent p-0 text-sm leading-[1.6] shadow-none focus-visible:ring-0"
                @focus="isReplyInputFocused = true"
                @blur="handleReplyBlur"
              />
              <div
                class="mt-2 flex items-center justify-between gap-2 border-t border-[var(--divider)] pt-2"
              >
                <span class="text-xs tabular-nums text-[var(--ink-tertiary)]">
                  {{ replyContent.length }}
                </span>
                <div class="flex items-center gap-2">
                  <Button
                    variant="ghost"
                    size="sm"
                    class="h-8 rounded-full"
                    :disabled="replyPending"
                    @click="toggleReplyBox"
                  >
                    {{ t('common.cancel') }}
                  </Button>
                  <AppSendButton
                    size="sm"
                    class="h-8 rounded-full font-semibold"
                    :disabled="replyPending || !replyContent.trim()"
                    @click="handleSubmitReply"
                  >
                    {{ t('comment.submitReply') }}
                  </AppSendButton>
                </div>
              </div>
            </div>
          </Transition>
        </div>
      </div>
    </div>

    <div
      v-if="comment.children && comment.children.length > 0"
      class="pb-2"
    >
      <CommentCard
        v-for="childComment in comment.children"
        :key="childComment.id"
        :comment="childComment"
        :level="level + 1"
        :enable-delete="enableDelete"
        :allow-reply="allowReply"
        :pending-like-ids="pendingLikeIds"
        :submit-reply="submitReply"
        @like-comment="$emit('like-comment', $event)"
        @submit-reply="$emit('submit-reply', $event)"
        @delete-comment="$emit('delete-comment', $event)"
      />
    </div>
  </div>
</template>
