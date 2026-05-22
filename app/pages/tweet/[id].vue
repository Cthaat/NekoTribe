<script lang="ts" setup>
import { computed, ref, watch } from 'vue';
import type {
  CreatePostFormVM,
  CommentVM,
  PostVM,
  PreviewPostVM
} from '@/services';
import {
  v2BookmarkPost,
  v2CreateComment,
  v2CreatePost,
  v2CreateRetweet,
  v2DeletePost,
  v2GetPost,
  v2LikeComment,
  v2LikePost,
  v2ListComments,
  v2ListPostReplies,
  v2UnlikeComment,
  v2UnlikePost,
  v2UnbookmarkPost,
  v2UploadMedia
} from '@/services';
import TweetCard from '@/components/TweetCard.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import TweetList from '@/components/TweetList.vue';
import CommentSection from '@/components/CommentSection.vue';
import TweetComposer from '@/components/TweetComposer.vue';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  AlertTriangle,
  Inbox,
  Loader2,
  MessageSquare
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { useRoute } from 'vue-router';
import { usePreferenceStore } from '~/stores/user';

const route = useRoute();
const localePath = useLocalePath();
const preferenceStore = usePreferenceStore();
const { t } = useAppLocale();

const currentPostId = computed(() => Number(route.params.id));
const tweet = ref<PostVM | null>(null);
const comments = ref<CommentVM[]>([]);
const replyPosts = ref<PostVM[]>([]);
const tweetPending = ref(false);
const commentPending = ref(false);
const repliesPending = ref(false);
const tweetError = ref<string | null>(null);
const commentError = ref<string | null>(null);
const repliesError = ref<string | null>(null);
const repliesPage = ref(1);
const repliesPageSize = 10;
const repliesTotal = ref(0);
const repliesHasNext = ref(false);

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
const isSubmittingRetweet = ref(false);
const isReplyComposerOpen = ref(false);
const selectedTweetForReply = ref<PreviewPostVM | null>(null);
const isSubmittingReplyPost = ref(false);
const replyComposerRef =
  ref<InstanceType<typeof TweetComposer> | null>(null);

async function loadTweet() {
  tweetPending.value = true;
  tweetError.value = null;
  try {
    tweet.value = await v2GetPost(currentPostId.value);
  } catch (error) {
    tweetError.value =
      error instanceof Error
        ? error.message
        : t('post.feed.loadFailed');
  } finally {
    tweetPending.value = false;
  }
}

async function loadComments() {
  commentPending.value = true;
  commentError.value = null;
  try {
    const result = await v2ListComments(
      currentPostId.value,
      {
        page: 1,
        pageSize: 100,
        sort: 'oldest'
      }
    );
    comments.value = result.items;
  } catch (error) {
    commentError.value =
      error instanceof Error
        ? error.message
        : t('comment.feedback.loadFailed');
  } finally {
    commentPending.value = false;
  }
}

async function loadReplyPosts(reset = true): Promise<void> {
  if (reset) {
    repliesPage.value = 1;
    replyPosts.value = [];
  }

  repliesPending.value = true;
  repliesError.value = null;

  try {
    const result = await v2ListPostReplies(currentPostId.value, {
      page: repliesPage.value,
      pageSize: repliesPageSize,
      sort: 'oldest'
    });
    replyPosts.value = reset
      ? result.items
      : [...replyPosts.value, ...result.items];
    repliesTotal.value = result.total;
    repliesHasNext.value = result.hasNext;
  } catch (error) {
    repliesError.value =
      error instanceof Error
        ? error.message
        : t('post.replies.loadFailed');
    if (reset) replyPosts.value = [];
    repliesTotal.value = reset ? 0 : repliesTotal.value;
    repliesHasNext.value = false;
  } finally {
    repliesPending.value = false;
  }
}

async function loadMoreReplyPosts(): Promise<void> {
  if (repliesPending.value || !repliesHasNext.value) return;
  repliesPage.value += 1;
  await loadReplyPosts(false);
}

async function loadPageData(): Promise<void> {
  await Promise.all([
    loadTweet(),
    loadComments(),
    loadReplyPosts(true)
  ]);
}

await loadPageData();
openReplyFromRoute();

watch(
  () => route.params.id,
  async () => {
    await loadPageData();
    openReplyFromRoute();
  }
);

watch(
  () => route.query.reply,
  () => {
    openReplyFromRoute();
  }
);

function patchTweetItem(
  postId: number,
  updater: (post: PostVM) => PostVM
): void {
  if (tweet.value?.id === postId) {
    tweet.value = updater(tweet.value);
  }

  const replyIndex = replyPosts.value.findIndex(
    item => item.id === postId
  );
  const reply = replyPosts.value[replyIndex];
  if (replyIndex >= 0 && reply) {
    replyPosts.value[replyIndex] = updater(reply);
  }
}

function removeReplyPost(postId: number): void {
  const originalCount = replyPosts.value.length;
  replyPosts.value = replyPosts.value.filter(
    item => item.id !== postId
  );
  if (replyPosts.value.length !== originalCount) {
    repliesTotal.value = Math.max(repliesTotal.value - 1, 0);
  }
}

async function handleDeleteTweet(tweetId: number) {
  try {
    await v2DeletePost(tweetId);
    toast.success(t('post.feedback.deleted'));
    if (tweet.value?.id !== tweetId) {
      removeReplyPost(tweetId);
      return;
    }
    const rootPath = localePath(
      `/tweet/home/${preferenceStore.preferences.user.id}`
    );
    await navigateTo(rootPath);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : t('common.unknownError');
    toast.error(t('post.feedback.deleteFailed'), {
      description: message
    });
  }
}

function mapPostVmToPreview(post: PostVM): PreviewPostVM {
  return {
    id: post.id,
    author: {
      name: post.author.name,
      username: post.author.username,
      avatarUrl: post.author.avatarUrl
    },
    content: post.content
  };
}

function handleReplyTweet(tweetItem: PostVM): void {
  selectedTweetForReply.value = mapPostVmToPreview(tweetItem);
  isReplyComposerOpen.value = true;
}

function handleRetweetTweet(tweetItem: PostVM): void {
  selectedTweetForRetweet.value = tweetItem;
  isRetweetModalOpen.value = true;
}

async function handleSubmitRetweet({
  content,
  originalTweetId
}: {
  content: string;
  originalTweetId: number;
}) {
  isSubmittingRetweet.value = true;
  try {
    await v2CreateRetweet(originalTweetId, {
      content,
      visibility: 'public'
    });
    toast.success(t('post.feedback.retweeted'));
    await Promise.all([loadTweet(), loadReplyPosts(true)]);
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('post.feedback.retweetFailed');
    toast.error(message);
  } finally {
    isSubmittingRetweet.value = false;
    isRetweetModalOpen.value = false;
  }
}

async function handleLikeTweet(
  tweetItem: PostVM,
  action: 'like' | 'unlike'
) {
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweetItem.id)
        : await v2UnlikePost(tweetItem.id);
    patchTweetItem(tweetItem.id, current => ({
      ...current,
      viewer: {
        ...current.viewer,
        hasLiked: result.isLiked
      },
      counts: {
        ...current.counts,
        likes: result.likesCount
      }
    }));
  } catch {
    toast.error(t('common.operationFailed'));
  }
}

async function handleBookmarkTweet(
  tweetItem: PostVM,
  action: 'mark' | 'unmark'
) {
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweetItem.id)
        : await v2UnbookmarkPost(tweetItem.id);
    patchTweetItem(tweetItem.id, current => ({
      ...current,
      viewer: {
        ...current.viewer,
        hasBookmarked: result.isBookmarked
      }
    }));
  } catch {
    toast.error(t('common.operationFailed'));
  }
}

async function handleLikeTweetComment(
  commentId: number,
  action: 'likeComment' | 'unlikeComment'
) {
  try {
    const result =
      action === 'likeComment'
        ? await v2LikeComment(commentId)
        : await v2UnlikeComment(commentId);
    const index = comments.value.findIndex(
      item => item.id === commentId
    );
    if (index !== -1) {
      const currentComment = comments.value[index];
      if (!currentComment) return;
      comments.value[index] = {
        ...currentComment,
        viewer: {
          ...currentComment.viewer,
          hasLiked: result.isLiked
        },
        counts: {
          ...currentComment.counts,
          likes: result.likesCount
        }
      };
    }
  } catch {
    toast.error(t('comment.feedback.likeFailed'));
  }
}

async function handleTweetComment(content: string) {
  if (!tweet.value) return;
  try {
    await v2CreateComment(tweet.value.id, {
      content,
      parentCommentId: null
    });
    await loadComments();
  } catch {
    toast.error(t('comment.feedback.sendFailed'));
  }
}

async function handleReplyTweetComment(
  parentCommentId: number,
  content: string
) {
  if (!tweet.value) return;
  try {
    await v2CreateComment(tweet.value.id, {
      content,
      parentCommentId
    });
    await loadComments();
  } catch {
    toast.error(t('comment.feedback.sendFailed'));
  }
}

function openReplyFromRoute(): void {
  if (!tweet.value || route.query.reply !== '1') return;
  if (isReplyComposerOpen.value) return;
  handleReplyTweet(tweet.value);
}

function closeReplyComposer(): void {
  isReplyComposerOpen.value = false;
  selectedTweetForReply.value = null;
}

async function uploadReplyMedia(
  formData: FormData
): Promise<number[]> {
  const mediaIds: number[] = [];
  const fileEntries = formData.getAll('file');

  for (const [index, entry] of fileEntries.entries()) {
    if (!(entry instanceof File)) continue;
    const mediaFormData = new FormData();
    mediaFormData.append('file', entry);
    const altText = String(
      formData.get(`altText:${index}`) || ''
    );
    const description = String(
      formData.get(`description:${index}`) || ''
    );
    if (altText) mediaFormData.append('alt_text', altText);
    if (description) {
      mediaFormData.append('description', description);
    }
    const media = await v2UploadMedia(mediaFormData);
    mediaIds.push(media.media_id);
  }

  return mediaIds;
}

async function handleSubmitPostReply(
  submitForm: CreatePostFormVM,
  formData: FormData
): Promise<void> {
  const target = selectedTweetForReply.value;
  if (!target) return;

  isSubmittingReplyPost.value = true;
  try {
    const mediaIds = await uploadReplyMedia(formData);
    await v2CreatePost({
      ...submitForm,
      replyToPostId: target.id,
      repostOfPostId: null,
      quotedPostId: null,
      mediaIds
    });
    toast.success(t('post.feedback.replied'));
    replyComposerRef.value?.reset();
    isReplyComposerOpen.value = false;
    selectedTweetForReply.value = null;
    await Promise.all([loadTweet(), loadReplyPosts(true)]);
  } catch (error) {
    toast.error(t('post.feedback.replyFailed'), {
      description: error instanceof Error ? error.message : undefined
    });
  } finally {
    isSubmittingReplyPost.value = false;
  }
}

const pending = computed(
  () => tweetPending.value || commentPending.value
);
</script>

<template>
  <div class="bg-background pt-4">
    <div v-if="pending">
      <TweetCardSkeleton />
    </div>

    <div
      v-else-if="tweetError || commentError"
      class="mx-auto max-w-2xl px-4"
    >
      <div
        class="flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-rose-500/30 bg-rose-50/30 py-12 text-center dark:bg-rose-950/20"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 ring-1 ring-rose-500/20"
        >
          <AlertTriangle class="h-5 w-5 text-rose-500" />
        </span>
        <div class="grid gap-1">
          <p class="text-sm font-medium">
            {{ t('post.feed.loadFailed') }}
          </p>
          <p class="text-xs text-muted-foreground">
            {{ tweetError || commentError || '' }}
          </p>
        </div>
      </div>
    </div>

    <div v-else-if="tweet">
      <TweetCard
        :tweet="tweet"
        @delete-tweet="handleDeleteTweet"
        @reply-tweet="handleReplyTweet"
        @retweet-tweet="handleRetweetTweet"
        @like-tweet="handleLikeTweet"
        @bookmark-tweet="handleBookmarkTweet"
      />
      <RetweetModal
        v-if="selectedTweetForRetweet"
        v-model:open="isRetweetModalOpen"
        :tweet="selectedTweetForRetweet"
        :is-submitting="isSubmittingRetweet"
        @submit-retweet="handleSubmitRetweet"
      />
      <Dialog v-model:open="isReplyComposerOpen">
        <DialogContent
          class="flex max-h-[88vh] max-w-2xl flex-col overflow-hidden rounded-xl border-border/60 p-0"
        >
          <DialogHeader
            class="border-b border-border/60 bg-background/60 px-5 py-4 backdrop-blur"
          >
            <div class="flex items-start gap-3">
              <span
                class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
              >
                <MessageSquare class="h-3.5 w-3.5" />
              </span>
              <div class="min-w-0 grid gap-1">
                <DialogTitle
                  class="text-base font-semibold tracking-tight"
                >
                  {{ t('post.replies.composeTitle') }}
                </DialogTitle>
                <DialogDescription class="text-xs">
                  {{ t('post.replies.composeDescription') }}
                </DialogDescription>
              </div>
            </div>
          </DialogHeader>
          <div class="overflow-y-auto px-5 py-4">
            <TweetComposer
              v-if="selectedTweetForReply"
              ref="replyComposerRef"
              :reply-to="selectedTweetForReply"
              :is-submitting="isSubmittingReplyPost"
              @clear-reply="closeReplyComposer"
              @open-reply-dialog="isReplyComposerOpen = true"
              @submit="handleSubmitPostReply"
            />
          </div>
        </DialogContent>
      </Dialog>

      <section class="mx-auto mt-6 grid max-w-2xl gap-3 px-4 sm:px-0">
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <MessageSquare class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-base font-semibold tracking-tight">
              {{ t('post.replies.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{
                t('post.replies.total', { count: repliesTotal })
              }}
            </p>
          </div>
        </header>

        <div
          v-if="repliesPending && replyPosts.length === 0"
          class="grid gap-3"
        >
          <TweetCardSkeleton v-for="i in 2" :key="i" />
        </div>

        <div
          v-else-if="repliesError && replyPosts.length === 0"
          class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-rose-500/30 bg-rose-50/30 py-10 text-center dark:bg-rose-950/20"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 ring-1 ring-rose-500/20"
          >
            <AlertTriangle class="h-5 w-5 text-rose-500" />
          </span>
          <div class="grid gap-1">
            <p class="text-sm font-medium">
              {{ t('post.replies.loadFailed') }}
            </p>
            <p class="text-xs text-muted-foreground">{{ repliesError }}</p>
          </div>
        </div>

        <TweetList
          v-else-if="replyPosts.length > 0"
          :tweets="replyPosts"
          :show-relation-context="false"
          @delete-tweet="handleDeleteTweet"
          @reply-tweet="handleReplyTweet"
          @retweet-tweet="handleRetweetTweet"
          @like-tweet="handleLikeTweet"
          @bookmark-tweet="handleBookmarkTweet"
        />

        <div
          v-else
          class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border/60 bg-muted/10 py-10 text-center"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
          >
            <Inbox class="h-5 w-5 text-muted-foreground" />
          </span>
          <p class="text-sm text-muted-foreground">
            {{ t('post.replies.empty') }}
          </p>
        </div>

        <div
          v-if="replyPosts.length > 0"
          class="grid gap-2 pt-1"
        >
          <p
            v-if="repliesError"
            class="text-center text-xs text-destructive"
          >
            {{ repliesError }}
          </p>
          <Button
            v-if="repliesHasNext"
            variant="outline"
            class="mx-auto h-9 rounded-md shadow-xs"
            :disabled="repliesPending"
            @click="loadMoreReplyPosts"
          >
            <Loader2
              v-if="repliesPending"
              class="h-3.5 w-3.5 animate-spin"
            />
            {{
              repliesPending
                ? t('post.replies.loading')
                : t('post.replies.loadMore')
            }}
          </Button>
        </div>
      </section>

      <CommentSection
        :comments="comments"
        :post-id="tweet.id"
        @like-comment="handleLikeTweetComment"
        @submit-reply="handleReplyTweetComment"
        @send-reply="handleTweetComment"
      />
    </div>

    <div
      v-else
      class="mx-auto max-w-2xl px-4"
    >
      <div
        class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border/60 bg-muted/10 py-12 text-center"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
        >
          <Inbox class="h-5 w-5 text-muted-foreground" />
        </span>
        <p class="text-sm text-muted-foreground">
          {{ t('post.feed.unavailable') }}
        </p>
      </div>
    </div>
  </div>
</template>
