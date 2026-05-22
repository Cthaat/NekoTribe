<script setup lang="ts">
import { ref, computed } from 'vue';
import type { PropType } from 'vue';
import type { NestedCommentVM } from '@/types/posts';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import AppSendButton from '@/components/app/AppSendButton.vue';
import { Heart, MessageSquare, Trash2 } from 'lucide-vue-next';

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

const localIsLiked = ref(props.comment.viewer.hasLiked);
const localLikesCount = ref(props.comment.counts.likes);

const formattedDate = computed(() => {
  return new Date(props.comment.createdAt).toLocaleString(
    locale.value === 'zh' ? 'zh-CN' : 'en-US',
    {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    }
  );
});

const indentationStyle = computed(() => ({
  marginLeft: `${Math.min(props.level, 6) * 20}px`
}));

const fallbackInitial = computed(() => {
  const source =
    props.comment.author.name || props.comment.author.username || '?';
  return source.slice(0, 1).toUpperCase();
});

function toggleReplyBox() {
  isReplyBoxOpen.value = !isReplyBoxOpen.value;
  replyContent.value = '';
}

function handleLike() {
  localIsLiked.value = !localIsLiked.value;
  localLikesCount.value += localIsLiked.value ? 1 : -1;

  emit('like-comment', {
    commentId: props.comment.id,
    action: localIsLiked.value ? 'likeComment' : 'unlikeComment'
  });
}

function handleSubmitReply() {
  if (!replyContent.value.trim()) return;
  emit('submit-reply', {
    parentCommentId: props.comment.id,
    content: replyContent.value
  });
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
    :style="indentationStyle"
  >
    <div
      v-if="level > 0"
      class="pointer-events-none absolute -left-3 top-0 h-full w-px bg-border/70"
      aria-hidden="true"
    />

    <div
      class="group/comment min-w-0 rounded-lg px-3 py-2.5 transition-colors hover:bg-muted/30"
    >
      <div class="flex min-w-0 items-start gap-3">
        <Avatar class="h-8 w-8 shrink-0 ring-1 ring-border">
          <AvatarImage
            :src="comment.author.avatarUrl"
            :alt="comment.author.name"
          />
          <AvatarFallback class="text-xs">
            {{ fallbackInitial }}
          </AvatarFallback>
        </Avatar>

        <div class="min-w-0 flex-1">
          <div class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-0.5 text-sm">
            <span class="truncate font-semibold">
              {{ comment.author.name }}
            </span>
            <span class="truncate text-xs text-muted-foreground">
              @{{ comment.author.username }}
            </span>
            <span class="text-xs text-muted-foreground">·</span>
            <span class="text-xs text-muted-foreground">
              {{ formattedDate }}
            </span>
          </div>

          <p
            class="mt-1 whitespace-pre-wrap break-words text-sm leading-relaxed text-foreground"
          >
            {{ comment.content }}
          </p>

          <div class="mt-2 flex items-center gap-1">
            <Button
              variant="ghost"
              size="sm"
              class="h-7 gap-1.5 rounded-md px-2 text-xs text-muted-foreground transition-colors hover:bg-rose-500/10 hover:text-rose-600 dark:hover:text-rose-400"
              @click="handleLike"
            >
              <Heart
                class="h-3.5 w-3.5 transition-transform"
                :class="{
                  'fill-rose-600 text-rose-600 dark:fill-rose-400 dark:text-rose-400':
                    localIsLiked
                }"
              />
              <span class="tabular-nums font-medium">
                {{ localLikesCount }}
              </span>
            </Button>
            <Button
              variant="ghost"
              size="sm"
              class="h-7 gap-1.5 rounded-md px-2 text-xs text-muted-foreground transition-colors hover:bg-sky-500/10 hover:text-sky-600 dark:hover:text-sky-400"
              @click="toggleReplyBox"
            >
              <MessageSquare class="h-3.5 w-3.5" />
              <span class="font-medium">{{ t('comment.reply') }}</span>
            </Button>
            <Button
              v-if="enableDelete && comment.viewer.canDelete"
              variant="ghost"
              size="sm"
              class="h-7 gap-1.5 rounded-md px-2 text-xs text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
              @click="handleDelete"
            >
              <Trash2 class="h-3.5 w-3.5" />
              <span class="font-medium">{{ t('comment.delete') }}</span>
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
              v-if="isReplyBoxOpen"
              class="mt-3 rounded-lg border border-border/60 bg-card p-3 transition-colors"
              :class="{ 'border-ring/60 ring-2 ring-ring/20': isReplyInputFocused }"
            >
              <Textarea
                v-model="replyContent"
                :placeholder="t('comment.replyPlaceholder')"
                class="min-h-[60px] resize-none border-none bg-transparent p-0 text-sm shadow-none focus-visible:ring-0"
                @focus="isReplyInputFocused = true"
                @blur="handleReplyBlur"
              />
              <div
                class="mt-2 flex items-center justify-between gap-2 border-t border-border/40 pt-2"
              >
                <span class="text-xs tabular-nums text-muted-foreground">
                  {{ replyContent.length }}
                </span>
                <div class="flex items-center gap-2">
                  <Button
                    variant="ghost"
                    size="sm"
                    class="h-7"
                    @click="toggleReplyBox"
                  >
                    {{ t('common.cancel') }}
                  </Button>
                  <AppSendButton
                    size="sm"
                    class="h-7"
                    :disabled="!replyContent.trim()"
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
      class="mt-0.5"
    >
      <CommentCard
        v-for="childComment in comment.children"
        :key="childComment.id"
        :comment="childComment"
        :level="level + 1"
        :enable-delete="enableDelete"
        @like-comment="$emit('like-comment', $event)"
        @submit-reply="$emit('submit-reply', $event)"
        @delete-comment="$emit('delete-comment', $event)"
      />
    </div>
  </div>
</template>
