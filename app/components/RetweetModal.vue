<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import type { PropType } from 'vue';
import type { PostVM } from '@/types/posts';
import { Repeat2, X } from 'lucide-vue-next';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter
} from '@/components/ui/dialog';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Textarea } from '@/components/ui/textarea';
import { Button } from '@/components/ui/button';

const props = defineProps({
  open: {
    type: Boolean,
    default: false
  },
  tweet: {
    type: Object as PropType<PostVM>,
    required: true
  },
  isSubmitting: {
    type: Boolean,
    default: false
  }
});

const emit = defineEmits(['update:open', 'submit-retweet']);
const { t } = useAppLocale();

const quoteContent = ref('');

const internalOpen = computed({
  get: () => props.open,
  set: value => emit('update:open', value)
});

const authorInitials = computed(() =>
  (props.tweet.author.username ?? 'NT')
    .substring(0, 2)
    .toUpperCase()
);

function handleRetweet(): void {
  if (props.isSubmitting) return;
  emit('submit-retweet', {
    content: quoteContent.value,
    originalTweetId: props.tweet.id
  });
}

watch(internalOpen, isOpen => {
  if (!isOpen) {
    quoteContent.value = '';
  }
});
</script>

<template>
  <Dialog v-model:open="internalOpen">
    <DialogContent
      class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-[525px]"
    >
      <DialogHeader
        class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
      >
        <DialogTitle
          class="flex items-center gap-2 text-base font-semibold tracking-tight"
        >
          <span
            class="flex h-7 w-7 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
          >
            <Repeat2 class="h-4 w-4" />
          </span>
          {{ t('post.retweet.title') }}
        </DialogTitle>
      </DialogHeader>

      <div class="grid gap-4 px-5 py-4">
        <Textarea
          v-model="quoteContent"
          :placeholder="t('post.retweet.placeholder')"
          class="min-h-[96px] resize-none rounded-lg border-border/60 bg-muted/20 shadow-xs focus-visible:ring-2 focus-visible:ring-ring/20"
        />

        <div class="rounded-lg border border-border/60 bg-muted/30 p-3">
          <div class="flex items-center gap-2">
            <Avatar class="h-7 w-7 ring-1 ring-border">
              <AvatarImage
                :src="tweet.author.avatarUrl"
                :alt="tweet.author.username"
              />
              <AvatarFallback
                class="bg-primary/10 text-[10px] font-semibold text-primary"
              >
                {{ authorInitials }}
              </AvatarFallback>
            </Avatar>
            <span class="truncate text-sm font-semibold tracking-tight">
              {{ tweet.author.name }}
            </span>
            <span class="truncate text-xs text-muted-foreground">
              @{{ tweet.author.username }}
            </span>
          </div>
          <p
            class="mt-2 line-clamp-3 whitespace-pre-wrap text-sm text-muted-foreground"
          >
            {{ tweet.content }}
          </p>
        </div>
      </div>

      <DialogFooter
        class="flex flex-col-reverse gap-2 border-t border-border/60 bg-background/60 px-5 py-3 backdrop-blur sm:flex-row sm:justify-end"
      >
        <Button
          variant="outline"
          class="h-9 rounded-md shadow-xs"
          :disabled="isSubmitting"
          @click="internalOpen = false"
        >
          <X class="h-3.5 w-3.5" />
          {{ t('common.cancel') }}
        </Button>
        <Button
          class="h-9 rounded-md shadow-xs"
          :disabled="isSubmitting"
          @click="handleRetweet"
        >
          <Repeat2 class="h-3.5 w-3.5" />
          <span v-if="!isSubmitting">
            {{ t('post.retweet.submit') }}
          </span>
          <span v-else>
            {{ t('post.retweet.submitting') }}
          </span>
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
