<script lang="ts" setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
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
  UnconfirmedPostError,
  UnconfirmedRetweetError,
  v2DeletePost,
  v2DeleteComment,
  v2GetPost,
  v2LikeComment,
  v2LikePost,
  v2ListComments,
  v2ListPostReplies,
  v2ListPostRetweets,
  v2UnlikeComment,
  v2UnlikePost,
  v2UnbookmarkPost,
} from '@/services';
import TweetCard from '@/components/TweetCard.vue';
import PostLikersDialog from '@/components/PostLikersDialog.vue';
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
import { authQueueFor } from '@/services/auth-request-queue';
import { discussionDraft, stageDiscussionDraft } from '@/utils/ai-discussion-draft';

const route = useRoute();
const localePath = useLocalePath();
const preferenceStore = usePreferenceStore();
const { t } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const router = useRouter();
const owner = auth.revision;
const expired = ref(auth.isIdentityChanging);

const currentPostId = computed(() => Number(route.params.id));
const citedCommentId = computed(() => {
  const value = route.query.comment;
  return typeof value === 'string' && /^[1-9][0-9]{0,15}$/.test(value) &&
    value.trim() === value && Number.isSafeInteger(Number(value)) ? Number(value) : undefined;
});
const tweet = ref<PostVM | null>(null);
const comments = ref<CommentVM[]>([]);
const pendingCommentLikeIds = ref(new Set<number>());
const commentToDelete = ref<number | null>(null);
const deletingComment = ref(false);
const relatedPosts = ref<PostVM[]>([]);
type RelatedPostKind = 'replies' | 'retweets';
const relatedKind = ref<RelatedPostKind>('replies');
const tweetPending = ref(false);
const commentPending = ref(false);
const summaryPending = ref(false);
const relatedPending = ref(false);
const tweetError = ref<string | null>(null);
const commentError = ref<string | null>(null);
const relatedError = ref<string | null>(null);
const relatedPage = ref(1);
const relatedPageSize = 10;
const relatedTotal = ref(0);
const relatedHasNext = ref(false);
let commentsRevision = 0;
let commentViewRevision = 0;
let tweetRevision = 0;
let relatedRevision = 0;

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
const isSubmittingRetweet = ref(false);
const isReplyComposerOpen = ref(false);
const selectedTweetForReply = ref<PreviewPostVM | null>(null);
const isSubmittingReplyPost = ref(false);
const replyComposerRef =
  ref<InstanceType<typeof TweetComposer> | null>(null);

function active(): boolean {
  return !expired.value && !auth.isIdentityChanging && auth.revision === owner;
}

function currentPage() {
  const post = currentPostId.value;
  return () => active() && currentPostId.value === post;
}

async function openDiscussionSummary(): Promise<void> {
  const post = tweet.value;
  if (!active() || !preferenceStore.isLoggedIn || post?.id !== currentPostId.value ||
      post.visibility !== 'public' || citedCommentId.value !== undefined || summaryPending.value) return;
  const page = currentPage();
  const view = commentViewRevision;
  const source = tweetRevision;
  const valid = () => page() && view === commentViewRevision &&
    source === tweetRevision && citedCommentId.value === undefined;
  const seen = new Set(comments.value.filter(comment => comment.postId === post.id).map(comment => comment.id));
  summaryPending.value = true;
  try {
    const confirmed = seen.size
      ? (await v2ListComments(post.id, { page: 1, pageSize: 20, sort: 'oldest' })).items
        .filter(comment => comment.postId === post.id && seen.delete(comment.id))
      : [];
    if (!valid()) return;
    const updated = await v2GetPost(post.id);
    if (!valid()) return;
    const text = updated.id === post.id ? discussionDraft(updated, confirmed) : '';
    if (!text) throw Error('DISCUSSION_SUMMARY_UNAVAILABLE');
    const path = localePath('/ai/writing');
    const cancel = stageDiscussionDraft(app, auth.revision, text);
    try {
      if (await router.push(path) || router.currentRoute.value.path !== path) cancel();
    } catch (error) {
      cancel();
      throw error;
    }
  } catch {
    if (valid()) toast.error(t('aiWriting.summaryUnavailable'));
  } finally {
    summaryPending.value = false;
  }
}

function clearInteractions() {
  commentToDelete.value = null;
  closeReplyComposer();
  isRetweetModalOpen.value = false;
  selectedTweetForRetweet.value = null;
  isSubmittingRetweet.value = false;
  isSubmittingReplyPost.value = false;
}

function expire() {
  expired.value = true;
  tweet.value = null;
  comments.value = [];
  relatedPosts.value = [];
  clearInteractions();
}

let stopAuth: (() => void) | undefined;
onMounted(() => {
  stopAuth = auth.subscribe(() => {
    if (!active()) expire();
  });
  if (!active()) expire();
});
onBeforeUnmount(() => {
  stopAuth?.();
  expired.value = true;
});

async function loadTweet() {
  if (!active()) return;
  const revision = ++tweetRevision;
  const valid = currentPage();
  const apply = () => valid() && revision === tweetRevision;
  tweetPending.value = true;
  tweetError.value = null;
  try {
    const result = await v2GetPost(currentPostId.value);
    if (apply()) tweet.value = result;
  } catch (error) {
    if (!apply()) return;
    tweetError.value =
      error instanceof Error
        ? error.message
        : t('post.feed.loadFailed');
  } finally {
    if (apply()) tweetPending.value = false;
  }
}

async function loadComments() {
  if (!active()) return;
  const revision = ++commentsRevision;
  const postId = currentPostId.value;
  const commentId = citedCommentId.value;
  const current = () => active() && revision === commentsRevision &&
    postId === currentPostId.value && commentId === citedCommentId.value;
  commentPending.value = true;
  commentError.value = null;
  try {
    const result = await v2ListComments(
      postId,
      commentId !== undefined ? { commentId } : {
        page: 1,
        pageSize: 100,
        sort: 'oldest'
      }
    );
    if (!current()) return;
    comments.value = commentId === undefined
      ? result.items
      : result.items.filter(item => item.id === commentId && item.postId === postId);
  } catch (error) {
    if (!current()) return;
    commentError.value =
      error instanceof Error
        ? error.message
        : t('comment.feedback.loadFailed');
  } finally {
    if (current()) commentPending.value = false;
  }
}

async function loadRelatedPosts(reset = true): Promise<void> {
  if (!active() || !preferenceStore.isLoggedIn || citedCommentId.value !== undefined ||
      (!reset && (relatedPending.value || !relatedHasNext.value))) return;
  const revision = ++relatedRevision;
  const postId = currentPostId.value;
  const kind = relatedKind.value;
  const page = reset ? 1 : relatedPage.value + 1;
  const valid = currentPage();
  const apply = () => valid() && preferenceStore.isLoggedIn &&
    revision === relatedRevision && relatedKind.value === kind &&
    citedCommentId.value === undefined;
  if (reset) {
    relatedPosts.value = [];
    relatedTotal.value = 0;
    relatedHasNext.value = false;
  }

  relatedPending.value = true;
  relatedError.value = null;

  try {
    const list = kind === 'replies' ? v2ListPostReplies : v2ListPostRetweets;
    const result = await list(postId, {
      page,
      pageSize: relatedPageSize,
      sort: 'oldest'
    });
    if (!apply()) return;
    const seen = new Set(relatedPosts.value.map(post => post.id));
    const items = result.items.filter(post => {
      const source = kind === 'replies' ? post.replyToPostId : post.repostOfPostId;
      if (source !== postId || seen.has(post.id)) return false;
      seen.add(post.id);
      return true;
    });
    relatedPosts.value = [...relatedPosts.value, ...items];
    relatedPage.value = page;
    relatedTotal.value = result.total;
    relatedHasNext.value = result.hasNext;
  } catch (error) {
    if (!apply()) return;
    relatedError.value =
      error instanceof Error
        ? error.message
        : t(kind === 'replies' ? 'post.replies.loadFailed' : 'post.reposts.loadFailed');
  } finally {
    if (apply()) relatedPending.value = false;
  }
}

async function loadMoreRelatedPosts(): Promise<void> {
  await loadRelatedPosts(false);
}

function selectRelatedKind(kind: RelatedPostKind) {
  if (relatedKind.value === kind) return;
  relatedKind.value = kind;
  void loadRelatedPosts();
}

watch(() => preferenceStore.isLoggedIn, signedIn => {
  if (signedIn) {
    void loadRelatedPosts();
  } else {
    relatedRevision++;
    relatedPosts.value = [];
    relatedTotal.value = 0;
    relatedHasNext.value = false;
    relatedPending.value = false;
    relatedError.value = null;
  }
});

async function loadPageData(): Promise<void> {
  await Promise.all([
    loadTweet(),
    loadComments(),
    ...(citedCommentId.value === undefined ? [loadRelatedPosts(true)] : [])
  ]);
}

await loadPageData();
openReplyFromRoute();

watch(
  [currentPostId, citedCommentId],
  async ([id], [previousId]) => {
    if (!active()) return;
    commentViewRevision++;
    commentToDelete.value = null;
    comments.value = [];
    if (id !== previousId) {
      clearInteractions();
      relatedKind.value = 'replies';
      tweet.value = null;
      await loadPageData();
      openReplyFromRoute();
    } else {
      await Promise.all([
        loadComments(),
        ...(citedCommentId.value === undefined ? [loadRelatedPosts(true)] : [])
      ]);
    }
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

  const replyIndex = relatedPosts.value.findIndex(
    item => item.id === postId
  );
  const reply = relatedPosts.value[replyIndex];
  if (replyIndex >= 0 && reply) {
    relatedPosts.value[replyIndex] = updater(reply);
  }
}

function removeRelatedPost(postId: number): void {
  const originalCount = relatedPosts.value.length;
  relatedPosts.value = relatedPosts.value.filter(
    item => item.id !== postId
  );
  if (relatedPosts.value.length !== originalCount) {
    relatedTotal.value = Math.max(relatedTotal.value - 1, 0);
  }
}

async function handleDeleteTweet(tweetId: number) {
  const valid = currentPage();
  if (!valid()) return;
  try {
    await v2DeletePost(tweetId);
    if (!valid()) return;
    toast.success(t('post.feedback.deleted'));
    if (tweet.value?.id !== tweetId) {
      removeRelatedPost(tweetId);
      return;
    }
    const rootPath = localePath(
      `/tweet/home/${preferenceStore.preferences.user.id}`
    );
    await navigateTo(rootPath);
  } catch (error) {
    if (!valid()) return;
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
  if (!active()) return;
  selectedTweetForReply.value = mapPostVmToPreview(tweetItem);
  isReplyComposerOpen.value = true;
}

function handleRetweetTweet(tweetItem: PostVM): void {
  if (!active()) return;
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
  const valid = currentPage();
  if (!valid()) return;
  isSubmittingRetweet.value = true;
  try {
    await v2CreateRetweet(originalTweetId, {
      content,
      visibility: 'public'
    });
    if (!valid()) return;
    toast.success(t('post.feedback.retweeted'));
    await Promise.all([loadTweet(), loadRelatedPosts(true)]);
  } catch (error) {
    if (!valid()) return;
    const message =
      error instanceof UnconfirmedRetweetError
        ? t('post.feedback.retweetUnconfirmed')
        : error instanceof Error
        ? error.message
        : t('post.feedback.retweetFailed');
    toast.error(message);
  } finally {
    if (valid()) {
      isSubmittingRetweet.value = false;
      isRetweetModalOpen.value = false;
    }
  }
}

async function handleLikeTweet(
  tweetItem: PostVM,
  action: 'like' | 'unlike'
) {
  const valid = currentPage();
  if (!valid()) return;
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweetItem.id)
        : await v2UnlikePost(tweetItem.id);
    if (!valid()) return;
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
    if (valid()) toast.error(t('common.operationFailed'));
  }
}

async function handleBookmarkTweet(
  tweetItem: PostVM,
  action: 'mark' | 'unmark'
) {
  const valid = currentPage();
  if (!valid()) return;
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweetItem.id)
        : await v2UnbookmarkPost(tweetItem.id);
    if (!valid()) return;
    patchTweetItem(tweetItem.id, current => ({
      ...current,
      viewer: {
        ...current.viewer,
        hasBookmarked: result.isBookmarked
      }
    }));
  } catch {
    if (valid()) toast.error(t('common.operationFailed'));
  }
}

async function handleLikeTweetComment(
  commentId: number,
  action: 'likeComment' | 'unlikeComment'
) {
  const valid = currentPage();
  if (!valid() || pendingCommentLikeIds.value.has(commentId)) return;
  pendingCommentLikeIds.value.add(commentId);
  try {
    const result =
      action === 'likeComment'
        ? await v2LikeComment(commentId)
        : await v2UnlikeComment(commentId);
    if (!valid()) return;
    if (result.commentId !== commentId) {
      throw new Error('Invalid comment like response');
    }
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
    if (!valid()) return;
    if (typeof error === 'object' && error !== null &&
        'statusCode' in error && error.statusCode === 404) {
      comments.value = comments.value.filter(item => item.id !== commentId);
    }
    toast.error(t('comment.feedback.likeFailed'));
  } finally {
    pendingCommentLikeIds.value.delete(commentId);
  }
}

async function handleTweetComment(content: string) {
  const valid = currentPage();
  if (!valid() || !tweet.value) return;
  try {
    await v2CreateComment(tweet.value.id, {
      content,
      parentCommentId: null
    });
    if (valid()) await loadComments();
  } catch {
    if (valid()) toast.error(t('comment.feedback.sendFailed'));
  }
}

async function handleReplyTweetComment(
  parentCommentId: number,
  content: string
): Promise<boolean> {
  const valid = currentPage();
  if (!valid() || !tweet.value) return false;
  try {
    await v2CreateComment(tweet.value.id, {
      content,
      parentCommentId
    });
    if (!valid()) return false;
    toast.success(t('comment.feedback.replySubmitted'));
    await loadComments();
    return true;
  } catch {
    if (valid()) toast.error(t('comment.feedback.sendFailed'));
    return false;
  }
}

function requestCommentDelete(commentId: string | number) {
  const id = Number(commentId);
  if (!active() || deletingComment.value ||
      !comments.value.some(comment => comment.id === id && comment.viewer.canDelete)) {
    return;
  }
  commentToDelete.value = id;
}

function removeDeletedComment(id: number) {
  commentsRevision++;
  commentPending.value = false;
  comments.value = comments.value.filter(comment => comment.id !== id);
}

async function confirmCommentDelete() {
  const id = commentToDelete.value;
  const pageValid = currentPage();
  const cited = citedCommentId.value;
  const revision = commentViewRevision;
  const valid = () => pageValid() && citedCommentId.value === cited &&
    commentViewRevision === revision;
  if (id === null || deletingComment.value || !valid() ||
      !comments.value.some(comment => comment.id === id && comment.viewer.canDelete)) {
    return;
  }
  deletingComment.value = true;
  try {
    await v2DeleteComment(id);
    if (!valid()) return;
    removeDeletedComment(id);
    toast.success(t('comment.feedback.deleted'));
  } catch (error) {
    if (!valid()) return;
    if (typeof error === 'object' && error !== null &&
        'statusCode' in error && error.statusCode === 404) {
      removeDeletedComment(id);
    }
    toast.error(t('comment.feedback.deleteFailed'));
  } finally {
    deletingComment.value = false;
    commentToDelete.value = null;
  }
}

function openReplyFromRoute(): void {
  if (!active() || !tweet.value || route.query.reply !== '1') return;
  if (isReplyComposerOpen.value) return;
  handleReplyTweet(tweet.value);
}

function closeReplyComposer(): void {
  isReplyComposerOpen.value = false;
  selectedTweetForReply.value = null;
}

async function handleSubmitPostReply(
  submitForm: CreatePostFormVM
): Promise<void> {
  const valid = currentPage();
  const target = selectedTweetForReply.value;
  if (!valid() || !target || isSubmittingReplyPost.value) return;

  isSubmittingReplyPost.value = true;
  try {
    await v2CreatePost({
      ...submitForm,
      replyToPostId: target.id,
      repostOfPostId: null,
      quotedPostId: null
    });
    if (!valid()) return;
    toast.success(t('post.feedback.replied'));
    replyComposerRef.value?.reset();
    isReplyComposerOpen.value = false;
    selectedTweetForReply.value = null;
    await Promise.all([loadTweet(), loadRelatedPosts(true)]);
  } catch (error) {
    if (!valid()) return;
    if (error instanceof UnconfirmedPostError) {
      toast.error(t('post.feedback.postUnconfirmed'));
    } else {
      toast.error(t('post.feedback.replyFailed'), {
        description: error instanceof Error ? error.message : undefined
      });
    }
  } finally {
    if (valid()) isSubmittingReplyPost.value = false;
  }
}

</script>

<template>
  <div class="bg-background pt-4">
    <p v-if="expired" role="status" class="mx-auto max-w-2xl px-4 py-6">{{ t('visibility.sessionChanged') }}</p>
    <div v-else-if="tweetPending">
      <TweetCardSkeleton />
    </div>

    <div
      v-else-if="tweetError"
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
            {{ tweetError }}
          </p>
        </div>
        <Button variant="outline" @click="loadTweet">{{ t('common.retry') }}</Button>
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
      <PostLikersDialog
        v-if="preferenceStore.isLoggedIn && tweet.id === currentPostId"
        :key="currentPostId"
        :post-id="currentPostId"
      />
      <Button v-if="preferenceStore.isLoggedIn && tweet.id === currentPostId &&
        tweet.visibility === 'public' && tweet.content.trim() && citedCommentId === undefined"
        variant="outline" size="sm" :disabled="summaryPending" @click="openDiscussionSummary">
        {{ t(summaryPending ? 'common.loading' : 'aiWriting.summarizePost') }}
      </Button>
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

      <section v-if="preferenceStore.isLoggedIn && citedCommentId === undefined" class="mx-auto mt-6 grid max-w-2xl gap-3 px-4 sm:px-0">
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <MessageSquare class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <div class="flex flex-wrap gap-1">
              <Button size="sm" :variant="relatedKind === 'replies' ? 'secondary' : 'ghost'"
                :aria-pressed="relatedKind === 'replies'" @click="selectRelatedKind('replies')">
                {{ t('post.replies.title') }}
              </Button>
              <Button size="sm" :variant="relatedKind === 'retweets' ? 'secondary' : 'ghost'"
                :aria-pressed="relatedKind === 'retweets'" @click="selectRelatedKind('retweets')">
                {{ t('post.reposts.title') }}
              </Button>
            </div>
            <p class="text-xs text-muted-foreground">
              {{
                t(relatedKind === 'replies' ? 'post.replies.total' : 'post.reposts.total', { count: relatedTotal })
              }}
            </p>
          </div>
        </header>

        <div
          v-if="relatedPending && relatedPosts.length === 0"
          class="grid gap-3"
        >
          <TweetCardSkeleton v-for="i in 2" :key="i" />
        </div>

        <div
          v-else-if="relatedError && relatedPosts.length === 0"
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
            <p class="text-xs text-muted-foreground">{{ relatedError }}</p>
          </div>
        </div>

        <TweetList
          v-else-if="relatedPosts.length > 0"
          :tweets="relatedPosts"
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
            {{ t(relatedKind === 'replies' ? 'post.replies.empty' : 'post.reposts.empty') }}
          </p>
        </div>

        <div
          v-if="relatedPosts.length > 0 || relatedHasNext"
          class="grid gap-2 pt-1"
        >
          <p
            v-if="relatedError"
            class="text-center text-xs text-destructive"
          >
            {{ relatedError }}
          </p>
          <Button
            v-if="relatedHasNext"
            variant="outline"
            class="mx-auto h-9 rounded-md shadow-xs"
            :disabled="relatedPending"
            @click="loadMoreRelatedPosts"
          >
            <Loader2
              v-if="relatedPending"
              class="h-3.5 w-3.5 animate-spin"
            />
            {{
              relatedPending
                ? t('post.replies.loading')
                : t(relatedError ? 'common.retry' : relatedKind === 'replies' ? 'post.replies.loadMore' : 'post.reposts.loadMore')
            }}
          </Button>
        </div>
      </section>

      <div v-if="citedCommentId !== undefined" class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <p v-if="!commentPending && !commentError && !comments.length" role="status">{{ t('aiKnowledge.citedCommentMissing') }}</p>
        <NuxtLink :to="localePath(`/tweet/${currentPostId}`)" class="text-sm text-primary underline">{{ t('aiKnowledge.allComments') }}</NuxtLink>
      </div>
      <div v-if="commentPending" class="mx-auto max-w-2xl px-4 py-6" role="status">
        <Loader2 class="h-5 w-5 animate-spin" :aria-label="t('common.loading')" />
      </div>
      <div v-else-if="commentError" class="mx-auto grid max-w-2xl justify-items-start gap-2 px-4 py-6">
        <p role="alert">{{ t('comment.feedback.loadFailed') }}</p>
        <Button variant="outline" @click="loadComments">{{ t('common.retry') }}</Button>
      </div>
      <CommentSection
        v-else
        :comments="comments"
        :post-id="tweet.id"
        :pending-like-ids="pendingCommentLikeIds"
        @like-comment="handleLikeTweetComment"
        :submit-reply="handleReplyTweetComment"
        enable-delete
        @delete-comment="requestCommentDelete"
        @send-reply="handleTweetComment"
      />
      <Dialog
        :open="commentToDelete !== null"
        @update:open="open => { if (!open && !deletingComment) commentToDelete = null; }"
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{{ t('comment.deleteConfirmTitle') }}</DialogTitle>
            <DialogDescription>{{ t('comment.deleteConfirmBody') }}</DialogDescription>
          </DialogHeader>
          <div class="flex justify-end gap-2">
            <Button variant="outline" :disabled="deletingComment" @click="commentToDelete = null">
              {{ t('common.cancel') }}
            </Button>
            <Button variant="destructive" :disabled="deletingComment" @click="confirmCommentDelete">
              {{ t('comment.delete') }}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
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
