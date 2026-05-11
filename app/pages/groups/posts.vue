<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import {
  FileText,
  RefreshCw,
  Search,
  Users
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import GroupPostCard from '@/components/GroupPostCard.vue';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { Skeleton } from '@/components/ui/skeleton';
import {
  deleteGroupPost,
  listJoinedGroupPostFeed,
  setGroupPostLikeStatus,
  setGroupPostPinStatus
} from '@/services/groups';
import type { Group, GroupPost } from '@/types/groups';
import type { V2GroupPostListType } from '@/types/v2';
import { usePreferenceStore } from '~/stores/user';

const { t } = useAppLocale();
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

watch([selectedGroupId, selectedType], () => {
  void refreshPosts();
});

onMounted(() => {
  void refreshPosts();
});
</script>

<template>
  <div class="space-y-5">
    <div
      class="flex flex-col gap-3 rounded-md border bg-card/60 p-3 shadow-xs lg:flex-row lg:items-center lg:justify-between"
    >
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <FileText class="h-4 w-4 text-primary" />
          <h2 class="text-base font-semibold">
            {{ t('groups.posts.title') }}
          </h2>
        </div>
        <p class="mt-1 text-sm text-muted-foreground">
          {{ t('groups.posts.description') }}
        </p>
      </div>

      <div class="flex flex-col gap-2 sm:flex-row">
        <Select v-model="selectedGroupId">
          <SelectTrigger class="w-full sm:w-[220px]">
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
          <SelectTrigger class="w-full sm:w-[160px]">
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
          :disabled="loading"
          @click="handleRefresh"
        >
          <RefreshCw
            :class="[
              'h-4 w-4',
              { 'animate-spin': loading }
            ]"
          />
          {{ t('common.refresh') }}
        </Button>
      </div>
    </div>

    <div
      class="flex flex-col gap-2 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between"
    >
      <div class="flex items-center gap-2">
        <Badge variant="outline">
          {{ t('groups.posts.total', { count: total }) }}
        </Badge>
        <Badge v-if="selectedGroup" variant="secondary">
          {{ selectedGroup.name }}
        </Badge>
      </div>
    </div>

    <div v-if="loading" class="space-y-4">
      <div
        v-for="index in 3"
        :key="index"
        class="rounded-md border bg-card p-4"
      >
        <div class="flex items-center gap-3">
          <Skeleton class="h-10 w-10 rounded-full" />
          <div class="flex-1 space-y-2">
            <Skeleton class="h-4 w-32" />
            <Skeleton class="h-3 w-48" />
          </div>
        </div>
        <Skeleton class="mt-4 h-20 w-full" />
      </div>
    </div>

    <AppEmptyState
      v-else-if="error"
      :icon="Search"
      :title="t('groups.posts.loadFailed')"
      :description="error"
    >
      <Button variant="outline" @click="handleRefresh">
        <RefreshCw class="h-4 w-4" />
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

    <div v-else class="space-y-4">
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
        @share="handleShare"
      />

      <div v-if="hasNext" class="flex justify-center pt-2">
        <Button
          variant="outline"
          :disabled="loadingMore"
          @click="handleLoadMore"
        >
          <RefreshCw
            v-if="loadingMore"
            class="h-4 w-4 animate-spin"
          />
          {{ t('common.loadMore') }}
        </Button>
      </div>
    </div>
  </div>
</template>
