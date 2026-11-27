<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import {
  ArrowLeft,
  Globe,
  Loader2,
  Lock,
  MessageSquarePlus,
  Share2,
  Shield,
  Users
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import GroupPostCard from '@/components/GroupPostCard.vue';
import UserAvatar from '@/components/UserAvatar.vue';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Textarea } from '@/components/ui/textarea';
import { authQueueFor } from '@/services/auth-request-queue';
import {
  canPublishGroupPost,
  createGroupPost,
  deleteGroupPost,
  getGroupBySlug,
  groupMembershipAction,
  joinGroup,
  leaveGroup,
  listGroupPosts,
  setGroupPostLikeStatus,
  setGroupPostPinStatus
} from '@/services/groups';
import { usePreferenceStore } from '@/stores/user';
import type { Group, GroupPost } from '@/types/groups';
import type { V2GroupPostListType } from '@/types/v2';

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

const currentUserId = computed(() => preferences.preferences.user.id);
const group = ref<Group | null>(null);
const posts = ref<GroupPost[]>([]);
const postType = ref<V2GroupPostListType>('all');
const page = ref(1);
const pageSize = 10;
const total = ref(0);
const hasNext = ref(false);
const loading = ref(true);
const postsLoading = ref(false);
const loadingMore = ref(false);
const membershipPending = ref(false);
const error = ref<string | null>(null);
const pendingMutations = ref(new Set<number>());

const composerOpen = ref(false);
const composeContent = ref('');
const publishing = ref(false);

let requestRevision = 0;
let stopAuth: (() => void) | undefined;

const postTypeOptions: { value: V2GroupPostListType; labelKey: string }[] = [
  { value: 'all', labelKey: 'groups.posts.types.all' },
  { value: 'pinned', labelKey: 'groups.posts.types.pinned' },
  { value: 'announcement', labelKey: 'groups.posts.types.announcement' }
];

const membershipAction = computed(() => (group.value ? groupMembershipAction(group.value) : null));
const canPost = computed(() => !!group.value && canPublishGroupPost(group.value));
const canManage = computed(() => !!(group.value?.isOwner || group.value?.isAdmin));

const privacyIcon = computed(() => {
  switch (group.value?.privacy) {
    case 'private':
      return Lock;
    case 'secret':
      return Shield;
    default:
      return Globe;
  }
});

function groupPostLink(postId: number): string {
  const targetSlug = group.value?.slug || slug.value;
  return localePath(`/groups/${encodeURIComponent(targetSlug)}/posts/${postId}`);
}

async function copyShareLink(): Promise<void> {
  const path = localePath(`/groups/${encodeURIComponent(group.value?.slug || slug.value)}`);
  const url = typeof window !== 'undefined' ? new URL(path, window.location.origin).href : path;
  try {
    await navigator.clipboard.writeText(url);
    toast.success(t('groups.detailPage.copyLinkSuccess'));
  } catch {
    toast.info(url);
  }
}

async function fetchPosts(targetGroup: Group, nextPage = 1, append = false): Promise<void> {
  const rev = requestRevision;
  if (append) loadingMore.value = true;
  else postsLoading.value = true;
  try {
    const res = await app.runWithContext(() =>
      listGroupPosts(targetGroup.id, nextPage, pageSize, postType.value)
    );
    if (rev !== requestRevision) return;
    posts.value = append ? [...posts.value, ...res.posts] : res.posts;
    page.value = nextPage;
    total.value = res.total;
    hasNext.value = res.hasNext;
  } finally {
    if (rev === requestRevision) {
      postsLoading.value = false;
      loadingMore.value = false;
    }
  }
}

async function loadAll(): Promise<void> {
  const currentSlug = slug.value;
  const rev = ++requestRevision;
  error.value = null;
  if (!currentSlug) {
    group.value = null;
    posts.value = [];
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
    if (rev !== requestRevision) return;
    group.value = loadedGroup;
    await fetchPosts(loadedGroup, 1, false);
  } catch (err) {
    if (rev !== requestRevision) return;
    group.value = null;
    posts.value = [];
    error.value = err instanceof Error ? err.message : t('groups.detailPage.notFound');
  } finally {
    if (rev === requestRevision) loading.value = false;
  }
}

async function handleJoinOrLeave(): Promise<void> {
  if (!group.value || !membershipAction.value || membershipPending.value) return;
  const target = group.value;
  const rev = requestRevision;
  membershipPending.value = true;
  try {
    if (membershipAction.value.event === 'join') {
      const status = await joinGroup(target.id);
      if (rev !== requestRevision) return;
      toast.success(status === 'active' ? t('groups.feedback.joined') : t('groups.feedback.joinRequested'));
    } else {
      await leaveGroup(target.id);
      if (rev !== requestRevision) return;
      toast.success(t(target.membershipStatus === 'pending' ? 'groups.feedback.requestCanceled' : 'groups.feedback.left'));
    }
    await loadAll();
  } catch {
    if (rev === requestRevision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === requestRevision) membershipPending.value = false;
  }
}

async function submitPost(): Promise<void> {
  const target = group.value;
  const body = composeContent.value.trim();
  if (!target || !body || publishing.value) return;
  const rev = requestRevision;
  publishing.value = true;
  try {
    await createGroupPost(target.id, { content: body });
    if (rev !== requestRevision) return;
    composeContent.value = '';
    composerOpen.value = false;
    toast.success(t('groups.post.feedback.created'));
    await fetchPosts(target, 1, false);
  } catch {
    if (rev === requestRevision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === requestRevision) publishing.value = false;
  }
}

async function toggleLike(postId: number): Promise<void> {
  const targetGroup = group.value;
  const targetPost = posts.value.find(item => item.id === postId);
  if (!targetGroup || !targetPost || pendingMutations.value.has(postId)) return;
  pendingMutations.value = new Set(pendingMutations.value).add(postId);
  const rev = requestRevision;
  try {
    const res = await setGroupPostLikeStatus(targetGroup.id, postId, !targetPost.isLiked);
    if (rev !== requestRevision) return;
    posts.value = posts.value.map(item =>
      item.id === postId ? { ...item, isLiked: res.is_liked, likeCount: res.likes_count } : item
    );
  } catch {
    if (rev === requestRevision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === requestRevision) {
      const nextSet = new Set(pendingMutations.value);
      nextSet.delete(postId);
      pendingMutations.value = nextSet;
    }
  }
}

async function togglePin(postId: number, pinned: boolean): Promise<void> {
  const targetGroup = group.value;
  if (!targetGroup || pendingMutations.value.has(postId)) return;
  pendingMutations.value = new Set(pendingMutations.value).add(postId);
  const rev = requestRevision;
  try {
    await setGroupPostPinStatus(targetGroup.id, postId, pinned);
    if (rev !== requestRevision) return;
    posts.value = posts.value.map(item => (item.id === postId ? { ...item, isPinned: pinned } : item));
  } catch {
    if (rev === requestRevision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === requestRevision) {
      const nextSet = new Set(pendingMutations.value);
      nextSet.delete(postId);
      pendingMutations.value = nextSet;
    }
  }
}

async function handleDeletePost(postId: number): Promise<void> {
  const targetGroup = group.value;
  if (!targetGroup || pendingMutations.value.has(postId)) return;
  pendingMutations.value = new Set(pendingMutations.value).add(postId);
  const rev = requestRevision;
  try {
    await deleteGroupPost(targetGroup.id, postId);
    if (rev !== requestRevision) return;
    posts.value = posts.value.filter(item => item.id !== postId);
    total.value = Math.max(0, total.value - 1);
    toast.success(t('groups.post.feedback.deleted'));
  } catch {
    if (rev === requestRevision) toast.error(t('common.operationFailed'));
  } finally {
    if (rev === requestRevision) {
      const nextSet = new Set(pendingMutations.value);
      nextSet.delete(postId);
      pendingMutations.value = nextSet;
    }
  }
}

async function sharePost(postId: number): Promise<void> {
  const path = groupPostLink(postId);
  const url = typeof window !== 'undefined' ? new URL(path, window.location.origin).href : path;
  try {
    await navigator.clipboard.writeText(url);
    toast.success(t('groups.posts.shareCopied'));
  } catch {
    toast.info(url);
  }
}

watch(postType, () => {
  if (group.value) void fetchPosts(group.value, 1, false);
});

watch([slug, () => preferences.isLoggedIn], () => {
  void loadAll();
});

onMounted(() => {
  stopAuth = auth.subscribe(() => {
    void loadAll();
  });
  void loadAll();
});

onBeforeUnmount(() => {
  stopAuth?.();
  requestRevision++;
});
</script>

<template>
  <div class="space-y-5">
    <!-- Top bar -->
    <div class="flex items-center justify-between gap-3">
      <Button
        variant="secondary"
        size="sm"
        class="pressable rounded-full"
        @click="router.push(localePath('/groups/discover'))"
      >
        <ArrowLeft class="size-4" />
        <span>{{ t('groups.detailPage.backToGroups') }}</span>
      </Button>

      <Button
        v-if="group"
        variant="secondary"
        size="sm"
        class="pressable rounded-full"
        @click="copyShareLink"
      >
        <Share2 class="size-3.5" />
        <span>{{ t('groups.detailPage.shareLink') }}</span>
      </Button>
    </div>

    <div v-if="loading" class="space-y-4">
      <Skeleton class="h-52 w-full rounded-[20px]" />
      <Skeleton class="h-36 w-full rounded-[20px]" />
    </div>

    <AppEmptyState
      v-else-if="error || !group"
      :icon="Users"
      :title="t('groups.detailPage.notFound')"
      :description="error || undefined"
    >
      <Button variant="secondary" as-child class="rounded-full">
        <NuxtLink :to="localePath('/groups/discover')">
          {{ t('groups.detailPage.backToGroups') }}
        </NuxtLink>
      </Button>
    </AppEmptyState>

    <template v-else>
      <!-- Group Hero Bento Card -->
      <section class="bento-card overflow-hidden">
        <div class="h-32 bg-gradient-to-br from-primary/20 via-primary/10 to-secondary sm:h-40">
          <img
            v-if="group.coverImage"
            :src="group.coverImage"
            :alt="group.name"
            class="h-full w-full object-cover"
          />
        </div>

        <div class="space-y-4 p-5 sm:p-6">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div class="flex min-w-0 items-center gap-4">
              <UserAvatar
                :src="group.avatar"
                :name="group.name"
                :seed="group.id"
                size="lg"
                class="-mt-12 ring-4 ring-card"
              />
              <div class="min-w-0">
                <h1 class="truncate text-xl font-semibold tracking-tight text-foreground sm:text-2xl">
                  {{ group.name }}
                </h1>
                <div class="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                  <span v-if="group.slug" class="font-medium text-primary">@{{ group.slug }}</span>
                  <span class="inline-flex items-center gap-1 rounded-full bg-secondary px-2 py-0.5 font-medium text-foreground">
                    <component :is="privacyIcon" class="size-3" />
                    {{ t(`groups.filters.privacy.${group.privacy}`) }}
                  </span>
                  <span class="tabular-nums">{{ t('groups.stats.membersCount', { count: group.memberCount }) }}</span>
                </div>
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <Button
                v-if="membershipAction"
                :variant="membershipAction.event === 'leave' ? 'secondary' : 'default'"
                size="sm"
                class="pressable rounded-full px-4"
                :disabled="membershipPending"
                @click="handleJoinOrLeave"
              >
                {{ t(`groups.actions.${membershipAction.label}`) }}
              </Button>
              <Button
                v-if="canPost"
                size="sm"
                class="pressable rounded-full px-4"
                @click="composerOpen = !composerOpen"
              >
                <MessageSquarePlus class="size-3.5" />
                <span>{{ t('groups.posts.manualPublish') }}</span>
              </Button>
            </div>
          </div>

          <p v-if="group.description" class="text-sm leading-relaxed text-muted-foreground">
            {{ group.description }}
          </p>
        </div>
      </section>

      <!-- Inline quick post box for active members -->
      <section v-if="composerOpen && canPost" class="bento-card space-y-3 p-5">
        <Textarea
          v-model="composeContent"
          rows="3"
          :placeholder="t('groups.posts.manualContent')"
          :disabled="publishing"
        />
        <div class="flex justify-end gap-2">
          <Button variant="ghost" size="sm" class="rounded-full" :disabled="publishing" @click="composerOpen = false">
            {{ t('common.cancel') }}
          </Button>
          <Button size="sm" class="rounded-full px-4" :disabled="publishing || !composeContent.trim()" @click="submitPost">
            <Loader2 v-if="publishing" class="size-3.5 animate-spin" />
            <span>{{ t('groups.posts.manualPublish') }}</span>
          </Button>
        </div>
      </section>

      <!-- Filter pills -->
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="inline-flex rounded-full bg-secondary p-1">
          <button
            v-for="opt in postTypeOptions"
            :key="opt.value"
            type="button"
            class="rounded-full px-3.5 py-1.5 text-xs font-medium transition-colors"
            :class="postType === opt.value ? 'bg-card font-semibold text-foreground shadow-xs' : 'text-muted-foreground hover:text-foreground'"
            @click="postType = opt.value"
          >
            {{ t(opt.labelKey) }}
          </button>
        </div>
        <span class="text-xs tabular-nums text-muted-foreground">
          {{ t('groups.posts.total', { count: total }) }}
        </span>
      </div>

      <!-- Group Posts -->
      <div v-if="postsLoading" class="space-y-3">
        <Skeleton v-for="i in 3" :key="i" class="h-36 w-full rounded-[20px]" />
      </div>
      <AppEmptyState
        v-else-if="posts.length === 0"
        :icon="Users"
        :title="t('groups.posts.emptyTitle')"
        :description="t('groups.posts.emptyDescription')"
        compact
      />
      <div v-else class="space-y-3">
        <GroupPostCard
          v-for="post in posts"
          :key="post.id"
          :post="{ ...post, groupId: group.id }"
          :can-manage="canManage"
          :can-vote="canPost"
          :is-author="post.author.id === currentUserId"
          :mutation-pending="pendingMutations.has(post.id)"
          @like="toggleLike"
          @pin="id => togglePin(id, true)"
          @unpin="id => togglePin(id, false)"
          @delete="handleDeletePost"
          @comment="id => navigateTo(groupPostLink(id))"
          @share="sharePost"
        />

        <div v-if="hasNext" class="flex justify-center pt-2">
          <Button
            variant="secondary"
            size="sm"
            class="rounded-full"
            :disabled="loadingMore"
            @click="fetchPosts(group, page + 1, true)"
          >
            <Loader2 v-if="loadingMore" class="size-3.5 animate-spin" />
            <span>{{ t('common.loadMore') }}</span>
          </Button>
        </div>
      </div>
    </template>
  </div>
</template>
