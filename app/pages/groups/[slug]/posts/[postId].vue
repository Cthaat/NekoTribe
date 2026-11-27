<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { ArrowLeft, FileText, Share2 } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import CommentSection from '@/components/CommentSection.vue';
import GroupPostCard from '@/components/GroupPostCard.vue';
import ReadingProgressBar from '@/components/motion/ReadingProgressBar.vue';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { authQueueFor } from '@/services/auth-request-queue';
import {
  canPublishGroupPost,
  createGroupPostComment,
  deleteGroupPost,
  deleteGroupPostComment,
  getGroupBySlug,
  getGroupPost,
  listGroupPostComments,
  setGroupCommentLikeStatus,
  setGroupPostLikeStatus,
  setGroupPostPinStatus
} from '@/services/groups';
import { usePreferenceStore } from '@/stores/user';
import type { Group, GroupPost } from '@/types/groups';
import type { CommentVM } from '@/types/posts';

const { t } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();
const router = useRouter();
const app = useNuxtApp();
const auth = authQueueFor(app);
const preferences = usePreferenceStore();

const slug = computed(() => {
  const raw = route.params.slug;
  return Array.isArray(raw) ? String(raw[0] ?? '').trim() : typeof raw === 'string' ? raw.trim() : '';
});

const postId = computed(() => {
  const raw = route.params.postId;
  const text = Array.isArray(raw) ? String(raw[0] ?? '').trim() : typeof raw === 'string' ? raw.trim() : '';
  if (!/^[1-9][0-9]{0,15}$/.test(text)) return null;
  const num = Number(text);
  return Number.isSafeInteger(num) && num > 0 ? num : null;
});

const currentUserId = computed(() => preferences.preferences.user.id);
const group = ref<Group | null>(null);
const post = ref<GroupPost | null>(null);
const comments = ref<CommentVM[]>([]);
const commentsPage = ref(1);
const commentsHasNext = ref(false);
const loading = ref(true);
const commentsLoading = ref(false);
const mutationPending = ref(false);
const pendingCommentLikes = ref(new Set<number>());
const error = ref<string | null>(null);

let revision = 0;
let stopAuth: (() => void) | undefined;

const groupUrl = computed(() => localePath(`/groups/${encodeURIComponent(group.value?.slug || slug.value)}`));
const canComment = computed(() => post.value?.group?.canComment === true);
const canManage = computed(() => post.value?.group?.canManage === true);
const canVote = computed(() => !!group.value && canPublishGroupPost(group.value));

async function copyShareLink(): Promise<void> {
  if (!postId.value) return;
  const path = localePath(`/groups/${encodeURIComponent(group.value?.slug || slug.value)}/posts/${postId.value}`);
  const url = typeof window !== 'undefined' ? new URL(path, window.location.origin).href : path;
  try {
    await navigator.clipboard.writeText(url);
    toast.success(t('groups.posts.shareCopied'));
  } catch {
    toast.info(url);
  }
}

async function fetchComments(targetGroup: Group, targetPostId: number, nextPage = 1, append = false): Promise<void> {
  const rev = revision;
  commentsLoading.value = true;
  try {
    const res = await app.runWithContext(() =>
      listGroupPostComments(targetGroup.id, targetPostId, nextPage, 30, undefined, 'newest')
    );
    if (rev !== revision) return;
    comments.value = append ? [...comments.value, ...res.comments] : res.comments;
    commentsPage.value = nextPage;
    commentsHasNext.value = res.hasNext;
  } finally {
    if (rev === revision) commentsLoading.value = false;
  }
}

async function loadPostPage(): Promise<void> {
  const currentSlug = slug.value;
  const targetPostId = postId.value;
  const rev = ++revision;
  error.value = null;

  if (!currentSlug || !targetPostId) {
    group.value = null;
    post.value = null;
    comments.value = [];
    loading.value = false;
    return;
  }
  if (!preferences.isLoggedIn || auth.isIdentityChanging) {
    loading.value = false;
    return;
  }

  loading.value = true;
  try {
    const loadedGroup = await app.runWithContext(() => getGroupBySlug(currentSlug));
    if (rev !== revision) return;
    group.value = loadedGroup;

    const loadedPost = await app.runWithContext(() => getGroupPost(loadedGroup.id, targetPostId));
    if (rev !== revision) return;
    post.value = loadedPost;

    await fetchComments(loadedGroup, targetPostId, 1, false);
  } catch (err) {
    if (rev !== revision) return;
    post.value = null;
    comments.value = [];
    error.value = err instanceof Error ? err.message : t('groups.detailPage.postNotFound');
  } finally {
    if (rev === revision) loading.value = false;
  }
}

async function toggleLike(): Promise<void> {
  if (!group.value || !post.value || mutationPending.value) return;
  const rev = revision;
  mutationPending.value = true;
  try {
    const res = await setGroupPostLikeStatus(group.value.id, post.value.id, !post.value.isLiked);
    if (rev !== revision || !post.value) return;
    post.value = { ...post.value, isLiked: res.is_liked, likeCount: res.likes_count };
  } catch {
    if (rev === revision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === revision) mutationPending.value = false;
  }
}

async function togglePin(pinned: boolean): Promise<void> {
  if (!group.value || !post.value || mutationPending.value) return;
  const rev = revision;
  mutationPending.value = true;
  try {
    await setGroupPostPinStatus(group.value.id, post.value.id, pinned);
    if (rev !== revision || !post.value) return;
    post.value = { ...post.value, isPinned: pinned };
  } catch {
    if (rev === revision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === revision) mutationPending.value = false;
  }
}

async function handleDeletePost(): Promise<void> {
  if (!group.value || !post.value || mutationPending.value) return;
  const rev = revision;
  mutationPending.value = true;
  try {
    await deleteGroupPost(group.value.id, post.value.id);
    if (rev !== revision) return;
    toast.success(t('groups.post.feedback.deleted'));
    void router.replace(groupUrl.value);
  } catch {
    if (rev === revision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === revision) mutationPending.value = false;
  }
}

async function sendComment(content: string, parentCommentId?: number): Promise<boolean> {
  const targetGroup = group.value;
  const targetPost = post.value;
  const text = content.trim();
  if (!targetGroup || !targetPost || !text) return false;
  const rev = revision;
  try {
    await createGroupPostComment(targetGroup.id, targetPost.id, {
      content: text,
      ...(parentCommentId === undefined ? {} : { parent_comment_id: parentCommentId })
    });
    if (rev !== revision) return false;
    post.value = { ...targetPost, commentCount: targetPost.commentCount + 1 };
    await fetchComments(targetGroup, targetPost.id, 1, false);
    toast.success(t(parentCommentId === undefined ? 'comment.feedback.submitted' : 'comment.feedback.replySubmitted'));
    return true;
  } catch {
    if (rev === revision) toast.error(t('comment.feedback.sendFailed'));
    return false;
  }
}

function submitGroupReply(parentCommentId: number, content: string): Promise<boolean> {
  return sendComment(content, parentCommentId);
}

async function handleLikeComment(commentId: string | number, action: 'likeComment' | 'unlikeComment'): Promise<void> {
  if (!group.value || !post.value) return;
  const id = Number(commentId);
  if (!Number.isSafeInteger(id) || pendingCommentLikes.value.has(id)) return;
  const rev = revision;
  pendingCommentLikes.value.add(id);
  try {
    const res = await setGroupCommentLikeStatus(
      group.value.id,
      post.value.id,
      id,
      action === 'likeComment'
    );
    if (rev !== revision) return;
    comments.value = comments.value.map(comment =>
      comment.id === id
        ? { ...comment, viewer: { ...comment.viewer, hasLiked: res.isLiked }, counts: { ...comment.counts, likes: res.likesCount } }
        : comment
    );
  } catch {
    if (rev === revision) toast.error(t('comment.feedback.likeFailed'));
  } finally {
    pendingCommentLikes.value.delete(id);
  }
}

async function handleDeleteComment(commentId: string | number): Promise<void> {
  if (!group.value || !post.value) return;
  const id = Number(commentId);
  if (!Number.isSafeInteger(id)) return;
  const rev = revision;
  try {
    await deleteGroupPostComment(group.value.id, post.value.id, id);
    if (rev !== revision) return;
    comments.value = comments.value.filter(c => c.id !== id);
    post.value = { ...post.value, commentCount: Math.max(0, post.value.commentCount - 1) };
    toast.success(t('comment.feedback.deleted'));
  } catch {
    if (rev === revision) toast.error(t('comment.feedback.deleteFailed'));
  }
}

watch([slug, postId, () => preferences.isLoggedIn], () => {
  void loadPostPage();
});

onMounted(() => {
  stopAuth = auth.subscribe(() => {
    void loadPostPage();
  });
  void loadPostPage();
});

onBeforeUnmount(() => {
  stopAuth?.();
  revision++;
});
</script>

<template>
  <div class="space-y-4">
    <ReadingProgressBar v-if="post" />

    <div class="flex items-center justify-between gap-3">
      <Button variant="secondary" size="sm" as-child class="pressable rounded-full">
        <NuxtLink :to="groupUrl">
          <ArrowLeft class="size-4" />
          <span>{{ group?.name || t('groups.detailPage.backToGroup') }}</span>
        </NuxtLink>
      </Button>

      <Button v-if="post" variant="secondary" size="sm" class="pressable rounded-full" @click="copyShareLink">
        <Share2 class="size-3.5" />
        <span>{{ t('groups.detailPage.shareLink') }}</span>
      </Button>
    </div>

    <div v-if="loading" class="space-y-4">
      <Skeleton class="h-44 w-full rounded-[20px]" />
      <Skeleton class="h-28 w-full rounded-[20px]" />
    </div>

    <AppEmptyState
      v-else-if="error || !post"
      :icon="FileText"
      :title="t('groups.detailPage.postNotFound')"
      :description="error || undefined"
    >
      <Button variant="secondary" as-child class="rounded-full">
        <NuxtLink :to="groupUrl">
          {{ t('groups.detailPage.backToGroup') }}
        </NuxtLink>
      </Button>
    </AppEmptyState>

    <template v-else>
      <GroupPostCard
        :post="{ ...post, groupId: group?.id }"
        :can-manage="canManage"
        :can-vote="canVote"
        :is-author="post.author.id === currentUserId"
        :mutation-pending="mutationPending"
        @like="toggleLike"
        @pin="() => togglePin(true)"
        @unpin="() => togglePin(false)"
        @delete="handleDeletePost"
        @share="copyShareLink"
      />

      <CommentSection
        :comments="comments"
        :post-id="post.id"
        :pending-like-ids="pendingCommentLikes"
        :allow-comment="canComment"
        :comment-byte-limit="1000"
        enable-delete
        :submit-comment="sendComment"
        :submit-reply="submitGroupReply"
        @like-comment="handleLikeComment"
        @delete-comment="handleDeleteComment"
      />

      <div v-if="commentsHasNext && group" class="flex justify-center pt-1">
        <Button
          variant="secondary"
          size="sm"
          class="rounded-full"
          :disabled="commentsLoading"
          @click="fetchComments(group, post.id, commentsPage + 1, true)"
        >
          {{ commentsLoading ? t('common.loading') : t('common.loadMore') }}
        </Button>
      </div>
    </template>
  </div>
</template>
