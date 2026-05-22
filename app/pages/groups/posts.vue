<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import {
  FileText,
  Loader2,
  RefreshCw,
  Search,
  Users,
  X
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import GroupPostCard from '@/components/GroupPostCard.vue';
import CommentSection from '@/components/CommentSection.vue';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { Skeleton } from '@/components/ui/skeleton';
import { Textarea } from '@/components/ui/textarea';
import {
  createGroupPostComment,
  deleteGroupPost,
  deleteGroupPostComment,
  listGroupPostComments,
  listJoinedGroupPostFeed,
  setGroupCommentLikeStatus,
  setGroupPostLikeStatus,
  setGroupPostPinStatus
} from '@/services/groups';
import { v2CreateReport } from '@/api/v2/moderation';
import type { Group, GroupPost } from '@/types/groups';
import type {
  V2GroupPostListType,
  V2ModerationReportReason
} from '@/types/v2';
import type { CommentVM } from '@/types/posts';
import { usePreferenceStore } from '~/stores/user';

const { t } = useAppLocale();
const route = useRoute();
const preferenceStore = usePreferenceStore();

const pageSize = 10;
const selectedGroupId = ref('all');
const selectedType = ref<V2GroupPostListType>('all');
const groups = ref<Group[]>([]);
const posts = ref<GroupPost[]>([]);
const page = ref(1);
const total = ref(0);
const hasNext = ref(false);
const loading = ref(false);
const loadingMore = ref(false);
const error = ref<string | null>(null);
const commentDialogOpen = ref(false);
const commentPost = ref<GroupPost | null>(null);
const comments = ref<CommentVM[]>([]);
const commentsLoading = ref(false);
const reportDialogOpen = ref(false);
const reportPost = ref<GroupPost | null>(null);
const reportReason = ref<V2ModerationReportReason>('spam');
const reportDescription = ref('');
const isSubmittingReport = ref(false);

const typeOptions: {
  value: V2GroupPostListType;
  labelKey: string;
}[] = [
  { value: 'all', labelKey: 'groups.posts.types.all' },
  {
    value: 'pinned',
    labelKey: 'groups.posts.types.pinned'
  },
  {
    value: 'announcement',
    labelKey: 'groups.posts.types.announcement'
  }
];

const reportReasons: V2ModerationReportReason[] = [
  'spam',
  'harassment',
  'hate',
  'violence',
  'adult',
  'misinformation',
  'copyright',
  'other'
];

const currentUserId = computed(() =>
  Number(preferenceStore.preferences.user.id)
);

const selectedGroupNumericId = computed(() => {
  if (selectedGroupId.value === 'all') return undefined;
  const id = Number(selectedGroupId.value);
  return Number.isFinite(id) ? id : undefined;
});

const selectedGroup = computed(() => {
  const id = selectedGroupNumericId.value;
  if (!id) return null;
  return groups.value.find(group => group.id === id) ?? null;
});

function patchPost(
  postId: number,
  updater: (post: GroupPost) => GroupPost
): void {
  posts.value = posts.value.map(post =>
    post.id === postId ? updater(post) : post
  );
}

async function loadPosts(append: boolean): Promise<void> {
  if (append) {
    if (loadingMore.value || !hasNext.value) return;
    loadingMore.value = true;
  } else {
    loading.value = true;
  }
  error.value = null;

  const nextPage = append ? page.value + 1 : 1;

  try {
    const result = await listJoinedGroupPostFeed({
      groupId: selectedGroupNumericId.value,
      type: selectedType.value,
      page: nextPage,
      pageSize
    });
    groups.value = result.groups;
    posts.value = append
      ? [...posts.value, ...result.posts]
      : result.posts;
    page.value = nextPage;
    total.value = result.total;
    hasNext.value = result.hasNext;
  } catch (caught) {
    const message =
      caught instanceof Error
        ? caught.message
        : t('groups.posts.loadFailed');
    error.value = message;
    if (!append) {
      posts.value = [];
      total.value = 0;
      hasNext.value = false;
    }
    toast.error(t('groups.posts.loadFailed'), {
      description: message
    });
  } finally {
    loading.value = false;
    loadingMore.value = false;
  }
}

async function refreshPosts(): Promise<void> {
  await loadPosts(false);
}

async function handleLoadMore(): Promise<void> {
  await loadPosts(true);
}

async function handleRefresh(): Promise<void> {
  await refreshPosts();
  if (!error.value) {
    toast.success(t('groups.posts.refreshed'));
  }
}

async function handleLike(postId: number): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (!post?.group) return;
  const previousLiked = !!post.isLiked;
  const previousCount = post.likeCount;
  const nextLiked = !previousLiked;

  patchPost(postId, item => ({
    ...item,
    isLiked: nextLiked,
    likeCount: Math.max(
      0,
      item.likeCount + (nextLiked ? 1 : -1)
    )
  }));

  try {
    const result = await setGroupPostLikeStatus(
      post.group.id,
      post.id,
      nextLiked
    );
    patchPost(postId, item => ({
      ...item,
      isLiked: result.is_liked,
      likeCount: result.likes_count
    }));
  } catch (caught) {
    patchPost(postId, item => ({
      ...item,
      isLiked: previousLiked,
      likeCount: previousCount
    }));
    toast.error(t('groups.posts.likeFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  }
}

async function handlePin(
  postId: number,
  isPinned: boolean
): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (!post?.group) return;
  const previous = !!post.isPinned;
  patchPost(postId, item => ({
    ...item,
    isPinned
  }));

  try {
    await setGroupPostPinStatus(
      post.group.id,
      post.id,
      isPinned
    );
  } catch (caught) {
    patchPost(postId, item => ({
      ...item,
      isPinned: previous
    }));
    toast.error(t('groups.posts.pinFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  }
}

async function handleDelete(postId: number): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (!post?.group) return;

  try {
    await deleteGroupPost(post.group.id, post.id);
    posts.value = posts.value.filter(item => item.id !== postId);
    total.value = Math.max(total.value - 1, 0);
  } catch (caught) {
    toast.error(t('groups.posts.deleteFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  }
}

async function handleShare(postId: number): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (!post?.group || typeof window === 'undefined') return;
  const url = new URL(window.location.href);
  url.searchParams.set('group', String(post.group.id));
  url.searchParams.set('post', String(post.id));

  try {
    await navigator.clipboard?.writeText(url.toString());
    toast.success(t('groups.posts.shareCopied'));
  } catch {
    toast.info(url.toString());
  }
}

async function loadCommentsForPost(
  post: GroupPost
): Promise<void> {
  if (!post.group) return;
  commentsLoading.value = true;
  try {
    const result = await listGroupPostComments(
      post.group.id,
      post.id
    );
    comments.value = result.comments;
  } catch (caught) {
    comments.value = [];
    toast.error(t('comment.feedback.loadFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  } finally {
    commentsLoading.value = false;
  }
}

async function handleComment(postId: number): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (!post?.group) return;
  commentPost.value = post;
  commentDialogOpen.value = true;
  await loadCommentsForPost(post);
}

async function handleSendComment(
  content: string
): Promise<void> {
  const post = commentPost.value;
  if (!post?.group) return;
  try {
    const comment = await createGroupPostComment(
      post.group.id,
      post.id,
      { content }
    );
    comments.value = [comment, ...comments.value];
    patchPost(post.id, item => ({
      ...item,
      commentCount: item.commentCount + 1
    }));
  } catch (caught) {
    toast.error(t('comment.feedback.sendFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  }
}

async function handleSubmitCommentReply(
  parentCommentId: string | number,
  content: string
): Promise<void> {
  const post = commentPost.value;
  if (!post?.group) return;
  const parentId = Number(parentCommentId);
  if (!Number.isFinite(parentId)) return;
  try {
    const comment = await createGroupPostComment(
      post.group.id,
      post.id,
      {
        content,
        parent_comment_id: parentId
      }
    );
    comments.value = [comment, ...comments.value];
    patchPost(post.id, item => ({
      ...item,
      commentCount: item.commentCount + 1
    }));
  } catch (caught) {
    toast.error(t('comment.feedback.replyFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  }
}

async function handleLikeComment(
  commentId: string | number,
  action: 'likeComment' | 'unlikeComment'
): Promise<void> {
  const post = commentPost.value;
  if (!post?.group) return;
  const id = Number(commentId);
  if (!Number.isFinite(id)) return;
  try {
    await setGroupCommentLikeStatus(
      post.group.id,
      post.id,
      id,
      action === 'likeComment'
    );
  } catch (caught) {
    toast.error(t('comment.feedback.likeFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
    await loadCommentsForPost(post);
  }
}

async function handleDeleteComment(
  commentId: string | number
): Promise<void> {
  const post = commentPost.value;
  if (!post?.group) return;
  const id = Number(commentId);
  if (!Number.isFinite(id)) return;
  try {
    await deleteGroupPostComment(post.group.id, post.id, id);
    comments.value = comments.value.filter(
      comment => comment.id !== id
    );
    patchPost(post.id, item => ({
      ...item,
      commentCount: Math.max(0, item.commentCount - 1)
    }));
    toast.success(t('comment.feedback.deleted'));
  } catch (caught) {
    toast.error(t('comment.feedback.deleteFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  }
}

function handleReport(postId: number): void {
  const post = posts.value.find(item => item.id === postId);
  if (!post) return;
  reportPost.value = post;
  reportReason.value = 'spam';
  reportDescription.value = '';
  reportDialogOpen.value = true;
}

async function submitGroupPostReport(): Promise<void> {
  if (!reportPost.value) return;
  isSubmittingReport.value = true;
  try {
    await v2CreateReport({
      target_type: 'group_post',
      target_id: reportPost.value.id,
      reason: reportReason.value,
      description:
        reportDescription.value.trim() || undefined
    });
    toast.success(t('groups.post.feedback.reported'));
    reportDialogOpen.value = false;
    reportPost.value = null;
  } catch (caught) {
    toast.error(t('post.feedback.reportFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  } finally {
    isSubmittingReport.value = false;
  }
}

watch([selectedGroupId, selectedType], () => {
  void refreshPosts();
});

onMounted(async () => {
  const groupId = Number(route.query.group);
  if (Number.isFinite(groupId) && groupId > 0) {
    selectedGroupId.value = String(groupId);
  }
  await refreshPosts();
  const postId = Number(route.query.post);
  if (!Number.isFinite(postId)) return;
  if (route.query.report === '1') {
    handleReport(postId);
  } else if (route.query.comments === '1') {
    await handleComment(postId);
  }
});
</script>

<template>
  <div class="grid gap-5">
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
    >
      <div
        class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between"
      >
        <div class="flex items-start gap-3 min-w-0">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <FileText class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-sm font-semibold tracking-tight">
              {{ t('groups.posts.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t('groups.posts.description') }}
            </p>
          </div>
        </div>

        <div class="flex flex-col gap-2 sm:flex-row">
          <Select v-model="selectedGroupId">
            <SelectTrigger class="h-9 w-full shadow-xs sm:w-[220px]">
              <SelectValue
                :placeholder="t('groups.posts.groupPlaceholder')"
              />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">
                {{ t('groups.posts.allGroups') }}
              </SelectItem>
              <SelectItem
                v-for="group in groups"
                :key="group.id"
                :value="String(group.id)"
              >
                {{ group.name }}
              </SelectItem>
            </SelectContent>
          </Select>

          <Select v-model="selectedType">
            <SelectTrigger class="h-9 w-full shadow-xs sm:w-[160px]">
              <SelectValue
                :placeholder="t('groups.posts.typePlaceholder')"
              />
            </SelectTrigger>
            <SelectContent>
              <SelectItem
                v-for="option in typeOptions"
                :key="option.value"
                :value="option.value"
              >
                {{ t(option.labelKey) }}
              </SelectItem>
            </SelectContent>
          </Select>

          <Button
            variant="outline"
            class="h-9 rounded-md shadow-xs"
            :disabled="loading"
            @click="handleRefresh"
          >
            <RefreshCw
              :class="[
                'h-3.5 w-3.5',
                { 'animate-spin': loading }
              ]"
            />
            {{ t('common.refresh') }}
          </Button>
        </div>
      </div>
    </section>

    <div
      class="flex flex-wrap items-center gap-2 text-sm text-muted-foreground"
    >
      <span
        class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground"
      >
        <span class="tabular-nums">{{ total }}</span>
        {{ t('groups.posts.total', { count: total }) }}
      </span>
      <span
        v-if="selectedGroup"
        class="inline-flex items-center gap-1 rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 text-[11px] font-medium text-primary"
      >
        <Users class="h-3 w-3" />
        {{ selectedGroup.name }}
      </span>
    </div>

    <div v-if="loading" class="grid gap-3">
      <div
        v-for="index in 3"
        :key="index"
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-4 shadow-none"
      >
        <div class="flex items-center gap-3">
          <Skeleton class="h-10 w-10 rounded-full" />
          <div class="flex-1 grid gap-2">
            <Skeleton class="h-4 w-32" />
            <Skeleton class="h-3 w-48" />
          </div>
        </div>
        <Skeleton class="h-20 w-full" />
      </div>
    </div>

    <AppEmptyState
      v-else-if="error"
      :icon="Search"
      :title="t('groups.posts.loadFailed')"
      :description="error"
    >
      <Button
        variant="outline"
        class="h-9 rounded-md shadow-xs"
        @click="handleRefresh"
      >
        <RefreshCw class="h-3.5 w-3.5" />
        {{ t('common.refresh') }}
      </Button>
    </AppEmptyState>

    <AppEmptyState
      v-else-if="groups.length === 0"
      :icon="Users"
      :title="t('groups.posts.noGroupsTitle')"
      :description="t('groups.posts.noGroupsDescription')"
    />

    <AppEmptyState
      v-else-if="posts.length === 0"
      :icon="FileText"
      :title="t('groups.posts.emptyTitle')"
      :description="t('groups.posts.emptyDescription')"
    />

    <div v-else class="grid gap-3">
      <GroupPostCard
        v-for="post in posts"
        :key="`${post.group?.id ?? 'group'}-${post.id}`"
        :post="post"
        :can-manage="!!post.group?.canManage"
        :is-author="post.author.id === currentUserId"
        @like="handleLike"
        @pin="id => handlePin(id, true)"
        @unpin="id => handlePin(id, false)"
        @delete="handleDelete"
        @comment="handleComment"
        @report="handleReport"
        @share="handleShare"
      />

      <div v-if="hasNext" class="flex justify-center pt-1">
        <Button
          variant="outline"
          class="h-9 rounded-md shadow-xs"
          :disabled="loadingMore"
          @click="handleLoadMore"
        >
          <Loader2
            v-if="loadingMore"
            class="h-3.5 w-3.5 animate-spin"
          />
          {{ t('common.loadMore') }}
        </Button>
      </div>
    </div>

    <Dialog v-model:open="commentDialogOpen">
      <DialogContent
        class="flex max-h-[88vh] max-w-3xl flex-col overflow-hidden rounded-xl border-border/60 p-0"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
        >
          <DialogTitle
            class="flex items-center gap-2 text-base font-semibold tracking-tight"
          >
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-primary/10 text-primary"
            >
              <FileText class="h-4 w-4" />
            </span>
            {{ t('comment.title') }}
          </DialogTitle>
          <p
            v-if="commentPost?.group"
            class="pl-9 text-xs text-muted-foreground"
          >
            {{ commentPost.group.name }}
          </p>
        </DialogHeader>
        <div
          v-if="commentsLoading"
          class="grid gap-3 p-6"
        >
          <Skeleton class="h-20 w-full" />
          <Skeleton class="h-16 w-full" />
        </div>
        <div v-else class="min-h-0 flex-1 overflow-y-auto">
          <CommentSection
            v-if="commentPost"
            :comments="comments"
            :post-id="commentPost.id"
            enable-delete
            @send-reply="handleSendComment"
            @submit-reply="handleSubmitCommentReply"
            @like-comment="handleLikeComment"
            @delete-comment="handleDeleteComment"
          />
        </div>
      </DialogContent>
    </Dialog>

    <Dialog v-model:open="reportDialogOpen">
      <DialogContent
        class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-md"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
        >
          <DialogTitle
            class="flex items-center gap-2 text-base font-semibold tracking-tight"
          >
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 dark:text-rose-400"
            >
              <X class="h-4 w-4" />
            </span>
            {{ t('post.report.title') }}
          </DialogTitle>
          <p class="pl-9 text-xs text-muted-foreground">
            {{ t('post.report.description') }}
          </p>
        </DialogHeader>

        <div class="grid gap-4 px-5 py-4">
          <div class="grid gap-1.5">
            <Label
              for="group-post-report-reason"
              class="text-xs font-medium"
            >
              {{ t('post.report.reasonLabel') }}
            </Label>
            <Select v-model="reportReason">
              <SelectTrigger
                id="group-post-report-reason"
                class="h-9 w-full shadow-xs"
              >
                <SelectValue
                  :placeholder="t('post.report.reasonPlaceholder')"
                />
              </SelectTrigger>
              <SelectContent>
                <SelectItem
                  v-for="reason in reportReasons"
                  :key="reason"
                  :value="reason"
                >
                  {{ t(`moderation.filters.reasons.${reason}`) }}
                </SelectItem>
              </SelectContent>
            </Select>
          </div>

          <div class="grid gap-1.5">
            <Label
              for="group-post-report-description"
              class="text-xs font-medium"
            >
              {{ t('post.report.descriptionLabel') }}
            </Label>
            <Textarea
              id="group-post-report-description"
              v-model="reportDescription"
              :placeholder="t('post.report.descriptionPlaceholder')"
              class="min-h-24 resize-none shadow-xs"
              maxlength="1000"
            />
            <p class="text-[11px] text-muted-foreground">
              {{
                t('post.report.descriptionHint', {
                  count: reportDescription.length
                })
              }}
            </p>
          </div>
        </div>

        <DialogFooter
          class="flex flex-col-reverse gap-2 border-t border-border/60 bg-background/60 px-5 py-3 backdrop-blur sm:flex-row sm:justify-end"
        >
          <Button
            variant="outline"
            class="h-9 rounded-md shadow-xs"
            :disabled="isSubmittingReport"
            @click="reportDialogOpen = false"
          >
            <X class="h-3.5 w-3.5" />
            {{ t('common.cancel') }}
          </Button>
          <Button
            variant="destructive"
            class="h-9 rounded-md shadow-xs"
            :disabled="isSubmittingReport"
            @click="submitGroupPostReport"
          >
            <Loader2
              v-if="isSubmittingReport"
              class="h-3.5 w-3.5 animate-spin"
            />
            {{
              isSubmittingReport
                ? t('post.report.submitting')
                : t('post.report.submit')
            }}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>
</template>
