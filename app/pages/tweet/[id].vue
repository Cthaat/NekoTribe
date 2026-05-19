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
import {
  Alert,
  AlertDescription,
  AlertTitle
} from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
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
  } catch (error) {
    console.error('Failed to like/unlike tweet:', error);
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
  } catch (error) {
    console.error(
      'Failed to bookmark/unbookmark tweet:',
      error
    );
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
  } catch (error) {
    console.error('Failed to like comment:', error);
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
  } catch (error) {
    console.error('Failed to send tweet comment:', error);
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
  } catch (error) {
    console.error('Failed to send tweet comment:', error);
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
      class="p-8 text-center text-destructive"
    >
      <p>{{ t('post.feed.loadFailed') }}</p>
      <p class="text-sm mt-2">
        {{ tweetError || commentError || '' }}
      </p>
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
        <DialogContent class="sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle>{{ t('post.replies.composeTitle') }}</DialogTitle>
            <DialogDescription>
              {{ t('post.replies.composeDescription') }}
            </DialogDescription>
          </DialogHeader>
          <TweetComposer
            v-if="selectedTweetForReply"
            ref="replyComposerRef"
            :reply-to="selectedTweetForReply"
            :is-submitting="isSubmittingReplyPost"
            @clear-reply="closeReplyComposer"
            @open-reply-dialog="isReplyComposerOpen = true"
            @submit="handleSubmitPostReply"
          />
        </DialogContent>
      </Dialog>

      <section class="mx-auto mt-6 max-w-2xl px-4 sm:px-0">
        <div
          class="mb-3 flex items-center justify-between gap-3"
        >
          <div>
            <h2 class="text-lg font-semibold tracking-tight">
              {{ t('post.replies.title') }}
            </h2>
            <p class="text-sm text-muted-foreground">
              {{
                t('post.replies.total', {
                  count: repliesTotal
                })
              }}
            </p>
          </div>
        </div>

        <div
          v-if="repliesPending && replyPosts.length === 0"
          class="space-y-4"
        >
          <TweetCardSkeleton v-for="i in 2" :key="i" />
        </div>

        <Alert
          v-else-if="repliesError && replyPosts.length === 0"
          variant="destructive"
        >
          <AlertTitle>{{ t('post.replies.loadFailed') }}</AlertTitle>
          <AlertDescription>{{ repliesError }}</AlertDescription>
        </Alert>

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

        <Card
          v-else
          class="gap-0 border-dashed py-0"
        >
          <CardContent class="p-8 text-center text-sm text-muted-foreground">
            {{ t('post.replies.empty') }}
          </CardContent>
        </Card>

        <div
          v-if="replyPosts.length > 0"
          class="space-y-3 pt-2"
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
            class="mx-auto flex"
            :disabled="repliesPending"
            @click="loadMoreReplyPosts"
          >
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
      class="p-8 text-center text-muted-foreground"
    >
      <p>{{ t('post.feed.unavailable') }}</p>
    </div>
  </div>
</template>
