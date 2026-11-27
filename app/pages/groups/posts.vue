<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
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
import PostDraftsDialog from '@/components/PostDraftsDialog.vue';
import PostPollEditor from '@/components/PostPollEditor.vue';
import PostPollPanel from '@/components/PostPollPanel.vue';
import PostMarkdown from '@/components/PostMarkdown.vue';
import { openPostPollDraft, postPollPayload, type PostPollDraft } from '@/utils/post-poll-draft';
import { markdownBytes, markdownExcerpt, maxMarkdownBytes, validMarkdownBody } from '@/utils/post-markdown';
import { v2PublishPostDraft, v2SavePostDraft } from '@/api/v2/post-drafts';
import type { V2PostDraft } from '@/types/v2';
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
  canPublishGroupPost as canPublish,
  createGroupPost,
  createGroupPostComment,
  deleteGroupPost,
  deleteGroupPostComment,
  getGroupPost,
  listGroupPostComments,
  listJoinedGroupPostFeed,
  setGroupCommentLikeStatus,
  setGroupPostLikeStatus,
  setGroupPostPinStatus
} from '@/services/groups';
import { v2CreateReport } from '@/api/v2/moderation';
import { v2UploadMedia } from '@/api/v2/posts';
import { normalizePublicMediaUrl } from '@/utils/assets';
import type { Group, GroupPost } from '@/types/groups';
import type {
  V2GroupPostListType,
  V2ModerationReportReason
} from '@/types/v2';
import type { CommentVM } from '@/types/posts';
import { usePreferenceStore } from '~/stores/user';
import { authQueueFor } from '@/services/auth-request-queue';
import { discussionDraft, stageDiscussionDraft } from '@/utils/ai-discussion-draft';

const { t } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();
const router = useRouter();
const app = useNuxtApp();
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
const citedComment = ref<number>();
let commentRequest = 0;
const commentView = ref(0);
let pendingCommentView: number | undefined;
let postRequest = 0;
let routeTargetRequest = 0;
const pendingPostMutations = ref(new Set<number>());
const pendingCommentLikes = ref(new Set<number>());
let unsubscribe: (() => void) | undefined;
const comments = ref<CommentVM[]>([]);
const commentsLoading = ref(false);
const commentsFailed = ref(false);
const summaryPending = ref(false);
const commentOrder = ['newest', 'oldest', 'popular'] as const;
const commentSort = ref<(typeof commentOrder)[number]>('newest');
const commentsPage = ref(0);
const commentsHasNext = ref(false);
const reportDialogOpen = ref(false);
const reportPost = ref<GroupPost | null>(null);
const reportReason = ref<V2ModerationReportReason>('spam');
const reportDescription = ref('');
const isSubmittingReport = ref(false);
const composerGroup = ref<Group | null>(null);
const composeContent = ref('');
const composePoll = ref<PostPollDraft | null>(null);
const composeMarkdown = ref(false);
const composeAnnouncement = ref(false);
const draftListOpen = ref(false);
const savedDraftId = ref<number | null>(null);
let composeRequest: AbortController | undefined;
let attachmentRequest: AbortController | undefined;
const uploadingAttachment = ref(false);
const attachments = ref<Array<{ url: string; name: string }>>([]);
const publishing = ref(false);
const composeBytes = computed(() => markdownBytes(composeMarkdown.value ? composeContent.value : composeContent.value.trim()));
const composeLimit = computed(() => composeMarkdown.value ? maxMarkdownBytes : 4000);
const markdownReady = computed(() => !composeMarkdown.value || validMarkdownBody(composeContent.value));
const canSubmitPoll = computed(() => !composePoll.value || !!postPollPayload(composePoll.value));

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

function canPublishAnnouncement(group: Group): boolean {
  return group.membershipStatus === 'active' &&
    ['owner', 'admin', 'moderator'].some(role => role === group.membershipRole);
}

function closeComposer(): void {
  attachmentRequest?.abort();
  attachmentRequest = undefined;
  uploadingAttachment.value = false;
  attachments.value = [];
  composeRequest?.abort();
  composeRequest = undefined;
  publishing.value = false;
  composerGroup.value = null;
  composeContent.value = '';
  composePoll.value = null;
  composeMarkdown.value = false;
  composeAnnouncement.value = false;
  draftListOpen.value = false;
  savedDraftId.value = null;
}

async function attachGroupImage(event: Event): Promise<void> {
  const input = event.currentTarget as HTMLInputElement;
  const file = input.files?.[0];
  input.value = '';
  const group = composerGroup.value;
  if (!file || !group || selectedGroup.value?.id !== group.id ||
      !canPublish(selectedGroup.value) || publishing.value || uploadingAttachment.value ||
      authQueueFor(app).isIdentityChanging) return;
  if (file.type && !file.type.startsWith('image/')) {
    toast.error(t('groups.posts.manualAttachmentFailed'));
    return;
  }
  const revision = preferenceStore.authRevision();
  const controller = new AbortController();
  attachmentRequest = controller;
  uploadingAttachment.value = true;
  const current = () => attachmentRequest === controller &&
    preferenceStore.isAuthCurrent(revision) && composerGroup.value?.id === group.id;
  const form = new FormData();
  form.append('file', file);
  form.append('alt_text', file.name);
  try {
    const media = await v2UploadMedia(form, controller.signal);
    if (!current()) return;
    const url = media.public_url?.trim();
    if (media.media_type !== 'image' || !url || url.includes(',') ||
        !/^(?:https?:\/\/[^/]+|\/(?!\/))/i.test(url)) {
      throw Error('Invalid group image receipt');
    }
    if (attachments.value.some(item => item.url === url)) return;
    const next = [...attachments.value, { url, name: file.name }];
    if (new TextEncoder().encode(next.map(item => item.url).join(',')).length > 2000) {
      toast.error(t('groups.posts.manualAttachmentLimit'));
      return;
    }
    attachments.value = next;
  } catch {
    if (current()) toast.error(t('groups.posts.manualAttachmentFailed'));
  } finally {
    if (attachmentRequest === controller) {
      attachmentRequest = undefined;
      uploadingAttachment.value = false;
    }
  }
}

function resumeGroupDraft(draft: V2PostDraft) {
  const {payload} = draft;
  if (payload.group_id === null || payload.group_id !== composerGroup.value?.id || publishing.value) return;
  savedDraftId.value = draft.draft_id;
  composeMarkdown.value = payload.markdown !== undefined;
  composeContent.value = payload.markdown ?? payload.content;
  composeAnnouncement.value = payload.is_announcement ?? false;
  composePoll.value = payload.poll ? openPostPollDraft(payload.poll) : null;
  attachments.value = (payload.media_urls ?? []).map((url,index) => ({url,name:t('post.drafts.attachment',{index:index+1})}));
}

async function submitGroupPost(purpose: 'publish' | 'save'): Promise<void> {
  const group = composerGroup.value;
  if (!group || selectedGroup.value?.id !== group.id || !canPublish(selectedGroup.value) ||
      publishing.value || uploadingAttachment.value || (purpose === 'publish' && !composeBytes.value) ||
      composeBytes.value > composeLimit.value || !markdownReady.value ||
      authQueueFor(app).isIdentityChanging) return;
  const poll = postPollPayload(composePoll.value);
  if (composePoll.value && !poll) return;
  const revision = preferenceStore.authRevision();
  const controller = new AbortController();
  composeRequest = controller;
  publishing.value = true;
  const current = () => composeRequest === controller &&
    preferenceStore.isAuthCurrent(revision) && composerGroup.value?.id === group.id;
  try {
    const markdown = composeMarkdown.value ? composeContent.value : undefined;
    const payload = {
      ...(poll ? {poll} : {}),
      ...(markdown === undefined ? {} : {markdown}),
      content: markdown === undefined ? composeContent.value.trim() : markdownExcerpt(markdown),
      media_urls: attachments.value.map(item => item.url),
      is_announcement: composeAnnouncement.value && canPublishAnnouncement(selectedGroup.value)
    };
    if (purpose === 'save' || savedDraftId.value !== null) {
      const saved = await app.runWithContext(() => v2SavePostDraft({group_id:group.id,...payload},savedDraftId.value,controller.signal));
      if (!current()) return;
      savedDraftId.value = saved.draft_id;
      if (purpose === 'save') {
        toast.success(t('post.drafts.saved'));
        return;
      }
      await app.runWithContext(() => v2PublishPostDraft(saved.draft_id,controller.signal));
    } else {
      await createGroupPost(group.id, payload, controller.signal);
    }
    if (!current()) return;
    closeComposer();
    toast.success(t('groups.posts.manualPublished'));
    await app.runWithContext(refreshPosts);
  } catch {
    if (current()) {
      if (purpose === 'publish' && savedDraftId.value === null) closeComposer();
      toast.error(t(purpose === 'save' ? 'post.drafts.saveFailed' : 'groups.posts.manualPublishFailed'));
    }
  } finally {
    if (composeRequest === controller) {
      composeRequest = undefined;
      publishing.value = false;
    }
  }
}

function patchPost(
  postId: number,
  updater: (post: GroupPost) => GroupPost
): void {
  posts.value = posts.value.map(post =>
    post.id === postId ? updater(post) : post
  );
}

async function loadPosts(append: boolean): Promise<void> {
  if (authQueueFor(app).isIdentityChanging) return;
  const owner = preferenceStore.authRevision();
  if (append) {
    if (loading.value || loadingMore.value || !hasNext.value) return;
    loadingMore.value = true;
  } else {
    loading.value = true;
  }
  error.value = null;

  const request = append ? postRequest : ++postRequest;
  const valid = () => request === postRequest && preferenceStore.isAuthCurrent(owner);
  const nextPage = append ? page.value + 1 : 1;

  try {
    const result = await listJoinedGroupPostFeed({
      groupId: selectedGroupNumericId.value,
      type: selectedType.value,
      page: nextPage,
      pageSize
    }, valid);
    if (!valid()) return;
    groups.value = result.groups;
    posts.value = append
      ? [...posts.value, ...result.posts]
      : result.posts;
    page.value = nextPage;
    total.value = result.total;
    hasNext.value = result.hasNext;
  } catch (caught) {
    if (!valid()) return;
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
    if (valid()) {
      loading.value = false;
      loadingMore.value = false;
    }
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

function isNotFound(caught: unknown): boolean {
  return typeof caught === 'object' && caught !== null &&
    'statusCode' in caught && caught.statusCode === 404;
}

function removePost(postId: number): void {
  if (!posts.value.some(post => post.id === postId)) return;
  posts.value = posts.value.filter(post => post.id !== postId);
  total.value = Math.max(total.value - 1, 0);
}

async function mutatePost(
  postId: number,
  errorKey: string,
  mutate: (groupId: number, post: GroupPost) => Promise<((post: GroupPost) => GroupPost) | null>,
  reload = false
): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (!post?.group || pendingPostMutations.value.has(postId)) return;
  const request = postRequest;
  const owner = preferenceStore.authRevision();
  const valid = () => request === postRequest && preferenceStore.isAuthCurrent(owner);
  if (authQueueFor(app).isIdentityChanging) return;
  pendingPostMutations.value.add(postId);
  try {
    const update = await mutate(post.group.id, post);
    if (!valid()) return;
    if (!update) {
      removePost(postId);
      toast.success(t('groups.post.feedback.deleted'));
      await app.runWithContext(refreshPosts);
      return;
    }
    if (reload) {
      await app.runWithContext(refreshPosts);
      return;
    }
    patchPost(postId, update);
    if (selectedType.value === 'pinned' &&
        posts.value.some(item => item.id === postId && !item.isPinned)) {
      removePost(postId);
    }
  } catch (caught) {
    if (!valid()) return;
    if (isNotFound(caught)) removePost(postId);
    toast.error(t(errorKey), {
      description: caught instanceof Error ? caught.message : undefined
    });
  } finally {
    pendingPostMutations.value.delete(postId);
  }
}

function handleLike(postId: number): Promise<void> {
  return mutatePost(postId, 'groups.posts.likeFailed', async (groupId, post) => {
    const result = await setGroupPostLikeStatus(groupId, post.id, !post.isLiked);
    return current => ({
      ...current,
      isLiked: result.is_liked,
      likeCount: result.likes_count
    });
  });
}

function handlePin(postId: number, isPinned: boolean): Promise<void> {
  return mutatePost(postId, 'groups.posts.pinFailed', async (groupId, post) => {
    const result = await setGroupPostPinStatus(groupId, post.id, isPinned);
    return current => ({ ...current, isPinned: result.is_pinned });
  }, true);
}

async function handleDelete(postId: number): Promise<void> {
  await mutatePost(postId, 'groups.posts.deleteFailed', async (groupId, post) => {
    await deleteGroupPost(groupId, post.id);
    return null;
  });
}

async function handleShare(postId: number): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (!post?.group || typeof window === 'undefined') return;
  const url = new URL(localePath('/groups/posts'), window.location.origin);
  url.searchParams.set('group', String(post.group.id));
  url.searchParams.set('post', String(post.id));

  try {
    if (!navigator.clipboard) {
      toast.info(url.toString());
      return;
    }
    await navigator.clipboard.writeText(url.toString());
    toast.success(t('groups.posts.shareCopied'));
  } catch {
    toast.info(url.toString());
  }
}

async function loadCommentsForPost(
  post: GroupPost,
  append = false
): Promise<void> {
  if (!post.group) return;
  const target = citedComment.value;
  if (append && (commentsLoading.value || !commentsHasNext.value || target !== undefined)) return;
  const request = ++commentRequest;
  const owner = preferenceStore.authRevision();
  const valid = () => commentDialogOpen.value && commentRequest === request &&
    preferenceStore.isAuthCurrent(owner);
  const next = append ? commentsPage.value + 1 : 1;
  commentsLoading.value = true;
  commentsFailed.value = false;
  if (!append) {
    comments.value = [];
    commentsPage.value = 0;
    commentsHasNext.value = false;
  }
  try {
    const result = await listGroupPostComments(
      post.group.id,
      post.id,
      next,
      target === undefined ? 20 : 1,
      target,
      commentSort.value
    );
    if (!valid()) return;
    const incoming = result.comments.filter(comment =>
      comment.postId === post.id && (target === undefined || comment.id === target));
    comments.value = [...new Map(
      (append ? [...comments.value, ...incoming] : incoming).map(comment => [comment.id, comment])
    ).values()];
    commentsPage.value = next;
    commentsHasNext.value = target === undefined && result.hasNext;
  } catch (caught) {
    if (!valid()) return;
    if (!append) commentsFailed.value = true;
    toast.error(t('comment.feedback.loadFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
  } finally {
    if (valid()) commentsLoading.value = false;
  }
}

async function handleComment(postId: number): Promise<void> {
  const post = posts.value.find(item => item.id === postId);
  if (post) await openCommentPost(post);
}

async function openCommentPost(post: GroupPost, commentId?: number): Promise<void> {
  if (!post?.group) return;
  commentView.value++;
  commentPost.value = post;
  commentSort.value = 'newest';
  citedComment.value = commentId;
  comments.value = [];
  commentDialogOpen.value = true;
  await loadCommentsForPost(post);
}

function changeCommentSort(value: unknown): void {
  const sort = commentOrder.find(option => option === value);
  const post = commentPost.value;
  if (!post || !sort || sort === commentSort.value) return;
  commentSort.value = sort;
  void loadCommentsForPost(post);
}

function showAllComments() {
  if (commentPost.value) void openCommentPost(commentPost.value);
}

function currentCommentScope() {
  const post = commentPost.value;
  const target = citedComment.value;
  const owner = preferenceStore.authRevision();
  const view = commentView.value;
  return () => commentDialogOpen.value && view === commentView.value && post === commentPost.value &&
    target === citedComment.value &&
    preferenceStore.isAuthCurrent(owner);
}

const canSummarizeDiscussion = computed(() =>
  preferenceStore.isLoggedIn && citedComment.value === undefined &&
  commentPost.value?.group?.privacy === 'public' &&
  commentPost.value.group.isActive === true &&
  Boolean(commentPost.value.content.trim())
);

async function summarizeGroupDiscussion(): Promise<void> {
  const post = commentPost.value;
  const auth = authQueueFor(app);
  if (!post?.group || !canSummarizeDiscussion.value || summaryPending.value ||
      auth.isIdentityChanging) return;
  const current = currentCommentScope();
  const revision = auth.revision;
  const viewed = commentRequest;
  const sort = commentSort.value;
  const seen = new Set(comments.value.filter(comment => comment.postId === post.id).map(comment => comment.id));
  const valid = () => current() && viewed === commentRequest &&
    !auth.isIdentityChanging && auth.revision === revision;
  const path = localePath('/ai/writing');
  summaryPending.value = true;
  try {
    const confirmed = seen.size
      ? (await listGroupPostComments(post.group.id, post.id, 1, 20, undefined, sort)).comments
        .filter(comment => comment.postId === post.id && seen.delete(comment.id))
      : [];
    if (!valid()) return;
    const updated = await getGroupPost(post.group.id, post.id);
    if (!valid()) return;
    const text = discussionDraft({
      id: updated.id,
      content: updated.content,
      visibility: updated.group?.isActive === true ? updated.group.privacy : 'private'
    }, confirmed);
    if (!text) throw Error('DISCUSSION_SUMMARY_UNAVAILABLE');
    const cancel = stageDiscussionDraft(app, revision, text);
    try {
      if (await router.push(path) || router.currentRoute.value.path !== path) cancel();
    } catch (error) {
      cancel();
      throw error;
    }
  } catch {
    if (valid()) toast.error(t('groups.posts.summaryUnavailable'));
  } finally {
    summaryPending.value = false;
  }
}

async function sendGroupComment(
  content: string,
  parentCommentId?: number
): Promise<boolean> {
  const post = commentPost.value;
  const view = commentView.value;
  const text = content.trim();
  if (!post?.group?.canComment || !commentDialogOpen.value ||
      pendingCommentView === view || authQueueFor(app).isIdentityChanging ||
      (parentCommentId !== undefined && (!Number.isSafeInteger(parentCommentId) ||
        !comments.value.some(comment => comment.id === parentCommentId && comment.postId === post.id)))) {
    return false;
  }
  if (!text || new TextEncoder().encode(text).length > 1000) {
    toast.error(t('groups.posts.replyTooLong'));
    return false;
  }
  const current = currentCommentScope();
  pendingCommentView = view;
  try {
    const reply = await createGroupPostComment(
      post.group.id,
      post.id,
      {
        content: text,
        ...(parentCommentId === undefined ? {} : { parent_comment_id: parentCommentId })
      }
    );
    if (!current()) return false;
    if (reply.postId !== post.id || (reply.parentCommentId ?? undefined) !== parentCommentId ||
        !Number.isSafeInteger(reply.id) || reply.id < 1) {
      toast.error(t('groups.posts.replyUnconfirmed'));
      return false;
    }
    if (citedComment.value === undefined) void app.runWithContext(() => loadCommentsForPost(post));
    patchPost(post.id, item => ({
      ...item,
      commentCount: item.commentCount + 1
    }));
    toast.success(t(parentCommentId === undefined ? 'comment.feedback.submitted' : 'comment.feedback.replySubmitted'));
    return true;
  } catch (caught) {
    if (!current()) return false;
    toast.error(t(parentCommentId === undefined ? 'comment.feedback.sendFailed' : 'comment.feedback.replyFailed'), {
      description:
        caught instanceof Error ? caught.message : undefined
    });
    return false;
  } finally {
    if (pendingCommentView === view) pendingCommentView = undefined;
  }
}

function replyToGroupComment(parentCommentId: number, content: string): Promise<boolean> {
  return sendGroupComment(content, parentCommentId);
}

async function handleLikeComment(
  commentId: string | number,
  action: 'likeComment' | 'unlikeComment'
): Promise<void> {
  const post = commentPost.value;
  if (!post?.group) return;
  const id = Number(commentId);
  if (!Number.isSafeInteger(id) || pendingCommentLikes.value.has(id)) return;
  const current = currentCommentScope();
  pendingCommentLikes.value.add(id);
  try {
    const result = await setGroupCommentLikeStatus(
      post.group.id,
      post.id,
      id,
      action === 'likeComment'
    );
    if (!current()) return;
    if (commentSort.value === 'popular' && citedComment.value === undefined) {
      void app.runWithContext(() => loadCommentsForPost(post));
      return;
    }
    comments.value = comments.value.map(comment => comment.id === id ? {
      ...comment,
      viewer: { ...comment.viewer, hasLiked: result.isLiked },
      counts: { ...comment.counts, likes: result.likesCount }
    } : comment);
  } catch (caught) {
    if (!current()) return;
    if (isNotFound(caught)) comments.value = comments.value.filter(comment => comment.id !== id);
    toast.error(t('comment.feedback.likeFailed'), {
      description: caught instanceof Error ? caught.message : undefined
    });
  } finally {
    pendingCommentLikes.value.delete(id);
  }
}

async function handleDeleteComment(
  commentId: string | number
): Promise<void> {
  const post = commentPost.value;
  if (!post?.group) return;
  const id = Number(commentId);
  if (!Number.isFinite(id)) return;
  const current = currentCommentScope();
  try {
    await deleteGroupPostComment(post.group.id, post.id, id);
    if (!current()) return;
    comments.value = comments.value.filter(
      comment => comment.id !== id
    );
    void app.runWithContext(() => loadCommentsForPost(post));
    patchPost(post.id, item => ({
      ...item,
      commentCount: Math.max(0, item.commentCount - 1)
    }));
    toast.success(t('comment.feedback.deleted'));
  } catch (caught) {
    if (!current()) return;
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
watch(selectedGroupId, closeComposer, { flush: 'sync' });
watch(commentDialogOpen, open => {
  if (!open) {
    commentView.value++;
    commentRequest++;
  }
}, { flush: 'sync' });

function clearComments() {
  commentRequest++;
  commentDialogOpen.value = false;
  commentPost.value = null;
  citedComment.value = undefined;
  comments.value = [];
  commentsLoading.value = false;
  commentsFailed.value = false;
  commentsHasNext.value = false;
  commentsPage.value = 0;
}

onMounted(() => {
  const queue = authQueueFor(app);
  unsubscribe = queue.subscribe(() => {
    clearComments();
    closeComposer();
    postRequest++;
    posts.value = [];
    groups.value = [];
    total.value = 0;
    hasNext.value = false;
    loading.value = false;
    loadingMore.value = false;
    if (!queue.isIdentityChanging && currentUserId.value > 0) void openRouteTarget();
  });
  void openRouteTarget();
});
onBeforeUnmount(() => {
  closeComposer();
  unsubscribe?.();
  postRequest++;
  commentRequest++;
  commentView.value++;
  routeTargetRequest++;
});
watch(() => route.fullPath, () => {
  clearComments();
  void openRouteTarget();
});

function routeGroupPostId(raw: unknown): number | undefined {
  if (typeof raw !== 'string' || raw.trim() !== raw ||
      !/^[1-9][0-9]{0,15}$/.test(raw)) return undefined;
  const id = Number(raw);
  return Number.isSafeInteger(id) ? id : undefined;
}

async function openRouteTarget() {
  const revision = preferenceStore.authRevision();
  const currentPath = route.fullPath;
  const request = ++routeTargetRequest;
  const current = () => request === routeTargetRequest &&
    preferenceStore.isAuthCurrent(revision) && route.fullPath === currentPath;
  const groupId = routeGroupPostId(route.query.group);
  const postId = routeGroupPostId(route.query.post);
  const knowledgeCitation = route.query.source === 'knowledge';
  if (groupId !== undefined && !knowledgeCitation) {
    selectedGroupId.value = String(groupId);
  }
  if (groupId !== undefined && postId !== undefined && route.query.report !== '1') {
    if (!knowledgeCitation) void app.runWithContext(refreshPosts);
    const target = routeGroupPostId(route.query.comment);
    try {
      const post = await app.runWithContext(() => getGroupPost(groupId, postId));
      if (current()) {
        if (knowledgeCitation) {
          if (post.group?.privacy !== 'public' || post.group.isActive !== true) {
            throw Error('GROUP_SOURCE_UNAVAILABLE');
          }
          selectedGroupId.value = String(groupId);
          void app.runWithContext(refreshPosts);
        }
        await app.runWithContext(() => openCommentPost(post, target));
      }
    } catch {
      if (current()) {
        toast.error(t('aiGroupDraft.sourceUnavailable'));
      }
    }
    return;
  }
  await refreshPosts();
  if (!current()) return;
  if (postId === undefined) return;
  if (route.query.report === '1') {
    handleReport(postId);
  } else if (route.query.comments === '1') {
    await handleComment(postId);
  }
}
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
          <Button
            v-if="selectedGroup && canPublish(selectedGroup)"
            :disabled="loading"
            @click="composerGroup = selectedGroup"
          >
            {{ t('groups.posts.manualPublish') }}
          </Button>
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

    <Dialog :open="composerGroup !== null" @update:open="open => { if (!open) closeComposer() }">
      <DialogContent v-if="composerGroup">
        <DialogHeader>
          <DialogTitle>{{ t('groups.posts.manualPublish') }} · {{ composerGroup.name }}</DialogTitle>
        </DialogHeader>
        <Label for="manual-group-post">{{ t('groups.posts.manualContent') }}</Label>
        <Textarea id="manual-group-post" v-model="composeContent" :disabled="publishing" rows="5" />
        <PostPollEditor v-model="composePoll" :disabled="publishing || uploadingAttachment" />
        <div class="flex flex-wrap items-center gap-3">
          <label class="flex items-center gap-2 text-sm">
            <input v-model="composeMarkdown" type="checkbox" :disabled="publishing" />{{ t('post.markdown.mode') }}
          </label>
          <span v-if="composeMarkdown" class="text-xs" :class="composeBytes > composeLimit ? 'text-destructive' : 'text-muted-foreground'">
            {{ t('post.markdown.size', {used:composeBytes,limit:composeLimit}) }}
          </span>
        </div>
        <p v-if="!composeMarkdown && composeBytes > composeLimit" class="text-sm text-destructive" role="alert">
          {{ t('groups.posts.manualTooLong') }}
        </p>
        <label v-if="canPublishAnnouncement(composerGroup)" class="flex items-center gap-2 text-sm">
          <input v-model="composeAnnouncement" type="checkbox" :disabled="publishing" />
          {{ t('groups.posts.manualAnnouncement') }}
        </label>
        <div class="grid gap-2">
          <Label for="manual-group-image">{{ t('groups.posts.manualAttachment') }}</Label>
          <input id="manual-group-image" type="file" accept="image/*"
            :disabled="publishing || uploadingAttachment" @change="attachGroupImage" />
          <p v-if="uploadingAttachment" class="text-sm text-muted-foreground" role="status">{{ t('groups.posts.manualUploading') }}</p>
          <ul v-if="attachments.length" class="flex max-h-36 flex-wrap gap-2 overflow-auto">
            <li v-for="item in attachments" :key="item.url" class="relative">
              <img :src="normalizePublicMediaUrl(item.url)" :alt="item.name" class="size-20 rounded-md object-cover" />
              <Button size="icon" variant="secondary" class="absolute right-0 top-0 size-6"
                :aria-label="t('groups.posts.manualRemoveAttachment')"
                :disabled="publishing || uploadingAttachment"
                @click="attachments = attachments.filter(image => image.url !== item.url)">
                <X class="size-4" />
              </Button>
            </li>
          </ul>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <Button type="button" size="sm" variant="outline" :disabled="publishing || uploadingAttachment" @click="draftListOpen = true">{{ t('post.drafts.title') }}</Button>
          <Button type="button" size="sm" variant="outline" :disabled="publishing || uploadingAttachment || composeBytes > composeLimit || !markdownReady || !canSubmitPoll" @click="submitGroupPost('save')">{{ t('post.drafts.save') }}</Button>
          <span v-if="savedDraftId !== null" class="text-xs text-muted-foreground">{{ t('post.drafts.editing') }}</span>
        </div>
        <PostDraftsDialog v-model:open="draftListOpen" :group-id="composerGroup.id" @resume="resumeGroupDraft"
          @removed="id => { if (id === savedDraftId) savedDraftId = null }" />
        <DialogFooter>
          <Button :disabled="publishing || uploadingAttachment || !composeBytes || composeBytes > composeLimit || !markdownReady || !canSubmitPoll" @click="submitGroupPost('publish')">
            {{ t('groups.posts.manualPublish') }}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <div
      class="flex flex-wrap items-center gap-2 text-sm text-muted-foreground"
    >
      <span
        class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium tabular-nums text-muted-foreground"
      >
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
        :can-vote="groups.some(group => group.id === post.groupId && canPublish(group))"
        :is-author="post.author.id === currentUserId"
        :mutation-pending="pendingPostMutations.has(post.id)"
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
          <div v-if="commentPost?.markdown" class="max-h-52 overflow-y-auto pl-9"><PostMarkdown :source="commentPost.markdown" /></div>
          <p v-else-if="commentPost" class="max-h-32 overflow-y-auto whitespace-pre-wrap break-words pl-9 text-sm">{{ commentPost.content }}</p>
          <PostPollPanel v-if="commentPost?.poll && commentPost.groupId" :key="commentPost.poll.poll_id"
            :poll="commentPost.poll" :post-id="commentPost.id" :group-id="commentPost.groupId"
            :can-vote="groups.some(group => group.id === commentPost?.groupId && canPublish(group))" />
          <Button v-if="canSummarizeDiscussion" variant="outline" size="sm"
            class="w-fit" :disabled="summaryPending" @click="summarizeGroupDiscussion">
            {{ t(summaryPending ? 'common.loading' : 'aiWriting.summarizePost') }}
          </Button>
        </DialogHeader>
        <div
          v-if="commentsLoading && !comments.length && citedComment !== undefined"
          class="grid gap-3 p-6"
        >
          <Skeleton class="h-20 w-full" />
          <Skeleton class="h-16 w-full" />
        </div>
        <div v-else class="min-h-0 flex-1 overflow-y-auto">
          <div v-if="citedComment === undefined" class="px-6 pt-3">
            <Select :model-value="commentSort" @update:model-value="changeCommentSort">
              <SelectTrigger class="w-36" :aria-label="t('groups.posts.commentOrder.label')">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem v-for="order in commentOrder" :key="order" :value="order">
                  {{ t(`groups.posts.commentOrder.${order}`) }}
                </SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div v-if="citedComment !== undefined" class="px-6 pt-3">
            <p v-if="!commentsFailed && !comments.length" role="status">{{ t('aiKnowledge.citedCommentMissing') }}</p>
            <Button type="button" variant="ghost" @click="showAllComments">{{ t('aiKnowledge.allComments') }}</Button>
          </div>
          <div v-if="commentsFailed && commentPost" class="px-6 pt-3">
            <Button variant="outline" @click="loadCommentsForPost(commentPost)">{{ t('common.retry') }}</Button>
          </div>
          <CommentSection
            v-if="commentPost"
            :key="commentView"
            :comments="comments"
            :post-id="commentPost.id"
            :pending-like-ids="pendingCommentLikes"
            :allow-comment="commentPost.group?.canComment === true"
            :comment-byte-limit="1000"
            enable-delete
            :submit-comment="sendGroupComment"
            :submit-reply="replyToGroupComment"
            @like-comment="handleLikeComment"
            @delete-comment="handleDeleteComment"
          />
          <div v-if="commentsHasNext || commentsLoading" class="px-6 pb-4">
            <Button v-if="commentPost" variant="outline" :disabled="commentsLoading"
              @click="loadCommentsForPost(commentPost, true)">
              {{ commentsLoading ? t('common.loading') : t('common.loadMore') }}
            </Button>
          </div>
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
