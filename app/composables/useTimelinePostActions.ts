import { shallowRef, ref, watch } from 'vue';
import { toast } from 'vue-sonner';
import type { PostVM } from '@/types/posts';
import type { PostFeedState } from '@/composables/usePostFeed';
import {
  v2BookmarkPost, v2CreateRetweet, UnconfirmedRetweetError, v2DeletePost,
  v2LikePost, v2UnlikePost, v2UnbookmarkPost,
} from '@/services/posts';

export function useTimelinePostActions(feed: PostFeedState, scope: () => string) {
  const { t } = useAppLocale();
  const localePath = useLocalePath();
  const isRetweetModalOpen = ref(false);
  const selectedTweetForRetweet = shallowRef<PostVM | null>(null);
  const isSubmittingRetweet = ref(false);
  watch(scope, () => {
    isRetweetModalOpen.value = false;
    selectedTweetForRetweet.value = null;
    isSubmittingRetweet.value = false;
  }, { flush: 'sync' });

  async function handleDeleteTweet(tweetId: number) {
    const current = scope();
    try {
      await v2DeletePost(tweetId);
      if (current !== scope()) return;
      toast.success(t('post.feedback.deleted'));
      feed.removePost(tweetId);
    } catch (error) {
      if (current !== scope()) return;
      toast.error(t('post.feedback.deleteFailed'), {
        description: error instanceof Error ? error.message : t('common.unknownError'),
      });
    }
  }

  function handleReplyTweet(tweet: PostVM) {
    return navigateTo(localePath(`/tweet/${tweet.id}?reply=1`), { replace: true });
  }

  function handleRetweetTweet(tweet: PostVM) {
    selectedTweetForRetweet.value = tweet;
    isRetweetModalOpen.value = true;
  }

  async function handleSubmitRetweet({ content, originalTweetId }: { content: string; originalTweetId: number }) {
    const current = scope();
    isSubmittingRetweet.value = true;
    try {
      await v2CreateRetweet(originalTweetId, { content, visibility: 'public' });
      if (current !== scope()) return;
      toast.success(t('post.feedback.retweeted'));
      await feed.refresh();
    } catch (error) {
      if (current !== scope()) return;
      const message = error instanceof UnconfirmedRetweetError ? t('post.feedback.retweetUnconfirmed') :
        error instanceof Error ? error.message : t('post.feedback.retweetFailed');
      toast.error(message);
    } finally {
      if (current === scope()) {
        isSubmittingRetweet.value = false;
        isRetweetModalOpen.value = false;
      }
    }
  }

  async function handleLikeTweet(tweet: PostVM, action: 'like' | 'unlike') {
    const current = scope();
    try {
      const result = await (action === 'like' ? v2LikePost(tweet.id) : v2UnlikePost(tweet.id));
      if (current !== scope()) return;
      feed.patchPost(tweet.id, post => ({
        ...post, viewer: { ...post.viewer, hasLiked: result.isLiked },
        counts: { ...post.counts, likes: result.likesCount },
      }));
    } catch {
      if (current === scope()) toast.error(t('common.operationFailed'));
    }
  }

  async function handleBookmarkTweet(tweet: PostVM, action: 'mark' | 'unmark') {
    const current = scope();
    try {
      const result = await (action === 'mark' ? v2BookmarkPost(tweet.id) : v2UnbookmarkPost(tweet.id));
      if (current !== scope()) return;
      feed.patchPost(tweet.id, post => ({ ...post, viewer: { ...post.viewer, hasBookmarked: result.isBookmarked } }));
    } catch {
      if (current === scope()) toast.error(t('common.operationFailed'));
    }
  }

  return {
    isRetweetModalOpen, selectedTweetForRetweet, isSubmittingRetweet, handleDeleteTweet, handleReplyTweet,
    handleRetweetTweet, handleSubmitRetweet, handleLikeTweet, handleBookmarkTweet,
  };
}
