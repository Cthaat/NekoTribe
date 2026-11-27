<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import {
  ArrowRight,
  Check,
  Compass,
  Flame,
  Hash,
  RefreshCw,
  UserPlus,
  Users
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import AppGlobalSearch from '@/components/AppGlobalSearch.vue';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import RetweetModal from '@/components/RetweetModal.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import TweetList from '@/components/TweetList.vue';
import UserAvatar from '@/components/UserAvatar.vue';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { v2ListTrendingTags } from '@/api/v2/posts';
import { usePostFeed } from '@/composables/usePostFeed';
import { useTimelinePostActions } from '@/composables/useTimelinePostActions';
import { authQueueFor } from '@/services/auth-request-queue';
import { listPopularGroups } from '@/services/groups';
import { v2ListTrendingPosts } from '@/services/posts';
import { v2FollowUser, v2RecommendedUsers, v2UnfollowUser } from '@/services/users';
import { usePreferenceStore } from '@/stores/user';
import type { Group } from '@/types/groups';
import type { PublicUserVM } from '@/types/users';
import type { V2TagItem } from '@/types/v2';

definePageMeta({
  layout: 'default'
});

const { t, locale } = useAppLocale();
const localePath = useLocalePath();
const app = useNuxtApp();
const auth = authQueueFor(app);
const preferences = usePreferenceStore();

const mounted = ref(false);
const generation = ref(0);
const sectionLoading = ref(false);
const tags = ref<V2TagItem[]>([]);
const popularGroups = ref<Group[]>([]);
const recommendedUsers = ref<PublicUserVM[]>([]);
const pendingFollowIds = ref(new Set<number>());

let stopAuth: (() => void) | undefined;
let discoverAbort: AbortController | undefined;

const trendingFeed = usePostFeed({
  debugName: 'discover-trending',
  pageSize: 10,
  loadPage: (page, pageSize) =>
    app.runWithContext(() => v2ListTrendingPosts({ page, pageSize }))
});

const actions = useTimelinePostActions(trendingFeed, () => String(generation.value));
const { isRetweetModalOpen, selectedTweetForRetweet, isSubmittingRetweet } = actions;

const numberFormatter = computed(
  () => new Intl.NumberFormat(locale.value === 'zh' ? 'zh-CN' : 'en-US')
);

function formatNumber(value: number): string {
  return numberFormatter.value.format(value);
}

async function loadSections(): Promise<void> {
  if (!mounted.value || !preferences.isLoggedIn || auth.isIdentityChanging) return;
  discoverAbort?.abort();
  const controller = new AbortController();
  discoverAbort = controller;
  const rev = generation.value;
  sectionLoading.value = true;
  try {
    const [tagsRes, groupsRes, usersRes] = await Promise.allSettled([
      app.runWithContext(() => v2ListTrendingTags(12, controller.signal)),
      app.runWithContext(() => listPopularGroups()),
      app.runWithContext(() => v2RecommendedUsers(6))
    ]);
    if (controller.signal.aborted || rev !== generation.value) return;
    tags.value = tagsRes.status === 'fulfilled' ? tagsRes.value.slice(0, 12) : [];
    popularGroups.value = groupsRes.status === 'fulfilled' ? groupsRes.value.groups.slice(0, 6) : [];
    recommendedUsers.value = usersRes.status === 'fulfilled' ? usersRes.value.slice(0, 6) : [];
  } finally {
    if (!controller.signal.aborted && rev === generation.value) {
      sectionLoading.value = false;
    }
  }
}

function refreshAll(): void {
  generation.value++;
  pendingFollowIds.value = new Set();
  trendingFeed.invalidate();
  trendingFeed.page = 1;
  if (mounted.value && preferences.isLoggedIn && !auth.isIdentityChanging) {
    void loadSections();
    void trendingFeed.refresh();
  }
}

function goToPage(page: number): void {
  if (page < 1 || page > trendingFeed.totalPages || trendingFeed.loading) return;
  generation.value++;
  trendingFeed.page = page;
  void trendingFeed.refresh();
}

async function toggleFollow(user: PublicUserVM): Promise<void> {
  if (pendingFollowIds.value.has(user.id)) return;
  const nextSet = new Set(pendingFollowIds.value).add(user.id);
  pendingFollowIds.value = nextSet;
  const rev = generation.value;
  const currentlyFollowing = user.relationship.isFollowing;
  try {
    const res = currentlyFollowing
      ? await v2UnfollowUser(user.id)
      : await v2FollowUser(user.id);
    if (rev !== generation.value) return;
    recommendedUsers.value = recommendedUsers.value.map(item =>
      item.id === user.id
        ? {
            ...item,
            followersCount: res.followersCount,
            relationship: {
              ...item.relationship,
              isFollowing: res.relationship === 'following',
              relation: res.relationship
            }
          }
        : item
    );
  } catch {
    if (rev === generation.value) {
      toast.error(t('common.operationFailed'));
    }
  } finally {
    if (rev === generation.value) {
      const remaining = new Set(pendingFollowIds.value);
      remaining.delete(user.id);
      pendingFollowIds.value = remaining;
    }
  }
}

watch(() => preferences.isLoggedIn, refreshAll, { flush: 'sync' });

onMounted(() => {
  stopAuth = auth.subscribe(refreshAll);
  mounted.value = true;
  refreshAll();
});

onBeforeUnmount(() => {
  stopAuth?.();
  discoverAbort?.abort();
  trendingFeed.invalidate();
});
</script>

<template>
  <div class="mx-auto max-w-[920px] space-y-5 px-3 py-4 sm:px-5 sm:py-6">
    <!-- Header & Search Hero -->
    <section class="bento-card grid gap-4 p-5 sm:p-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <div class="flex size-10 shrink-0 items-center justify-center rounded-2xl bg-[var(--primary-soft)] text-primary">
            <Compass class="size-5" />
          </div>
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-foreground">
              {{ t('discover.title') }}
            </h1>
            <p class="text-xs text-muted-foreground sm:text-sm">
              {{ t('discover.subtitle') }}
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <Button
            variant="secondary"
            size="sm"
            class="pressable rounded-full px-3.5"
            @click="refreshAll"
          >
            <RefreshCw class="size-3.5" />
            <span>{{ t('common.refresh') }}</span>
          </Button>
          <Button
            variant="ghost"
            size="sm"
            as-child
            class="pressable rounded-full px-3.5"
          >
            <NuxtLink :to="localePath('/?feed=trending')">
              <span>{{ t('discover.viewAllTrending') }}</span>
              <ArrowRight class="size-3.5" />
            </NuxtLink>
          </Button>
        </div>
      </div>

      <AppGlobalSearch class="max-w-none" />
    </section>

    <!-- Top Bento 2-column section: Trending Topics + Creators -->
    <section class="grid gap-4 lg:grid-cols-12">
      <!-- Trending Topics -->
      <div class="bento-card flex flex-col gap-3.5 p-5 lg:col-span-7">
        <div class="flex items-center justify-between gap-2">
          <h2 class="flex items-center gap-2 text-sm font-semibold tracking-tight text-foreground">
            <Hash class="size-4 text-primary" />
            <span>{{ t('discover.trendingTags') }}</span>
          </h2>
        </div>

        <div v-if="!mounted || sectionLoading" class="flex flex-wrap gap-2">
          <Skeleton v-for="i in 8" :key="i" class="h-8 w-24 rounded-full" />
        </div>
        <div v-else-if="tags.length" class="flex flex-wrap gap-2">
          <NuxtLink
            v-for="tag in tags"
            :key="tag.tag_id"
            :to="localePath(`/tags/${encodeURIComponent(tag.name)}`)"
            class="bento-tile pressable inline-flex items-center gap-2 px-3.5 py-2 text-xs font-medium text-foreground transition-colors hover:bg-[var(--primary-soft)] hover:text-primary"
          >
            <span class="font-semibold text-primary">#</span>
            <span class="max-w-[10rem] truncate">{{ tag.name }}</span>
            <span class="rounded-full bg-card px-1.5 py-0.5 text-[10px] tabular-nums text-muted-foreground">
              {{ formatNumber(tag.usage_count) }}
            </span>
          </NuxtLink>
        </div>
        <p v-else class="py-4 text-center text-xs text-muted-foreground">
          {{ t('discover.emptyTags') }}
        </p>
      </div>

      <!-- Suggested Creators -->
      <div class="bento-card flex flex-col gap-3.5 p-5 lg:col-span-5">
        <h2 class="flex items-center gap-2 text-sm font-semibold tracking-tight text-foreground">
          <UserPlus class="size-4 text-primary" />
          <span>{{ t('discover.recommendedUsers') }}</span>
        </h2>

        <div v-if="!mounted || sectionLoading" class="space-y-2.5">
          <div v-for="i in 4" :key="i" class="flex items-center gap-3">
            <Skeleton class="size-9 rounded-full" />
            <div class="flex-1 space-y-1.5">
              <Skeleton class="h-3.5 w-24" />
              <Skeleton class="h-3 w-16" />
            </div>
            <Skeleton class="h-7 w-16 rounded-full" />
          </div>
        </div>
        <div v-else-if="recommendedUsers.length" class="space-y-2">
          <div
            v-for="person in recommendedUsers"
            :key="person.id"
            class="bento-tile flex items-center justify-between gap-2.5 px-3 py-2.5"
          >
            <NuxtLink
              :to="localePath(`/user/${person.id}/profile`)"
              class="flex min-w-0 flex-1 items-center gap-2.5"
            >
              <UserAvatar
                :src="person.avatarUrl"
                :name="person.name"
                :username="person.username"
                :seed="person.id"
                size="sm"
              />
              <div class="min-w-0">
                <p class="truncate text-xs font-semibold text-foreground">
                  {{ person.name || person.username }}
                </p>
                <p class="truncate text-[11px] text-muted-foreground">
                  @{{ person.username }}
                </p>
              </div>
            </NuxtLink>
            <Button
              v-if="!person.relationship.isSelf"
              size="sm"
              :variant="person.relationship.isFollowing ? 'secondary' : 'default'"
              class="pressable h-7 shrink-0 rounded-full px-3 text-[11px]"
              :disabled="pendingFollowIds.has(person.id)"
              @click="toggleFollow(person)"
            >
              <Check v-if="person.relationship.isFollowing" class="size-3" />
              <span>{{
                person.relationship.isFollowing
                  ? t('discover.following')
                  : person.relationship.relation === 'requested'
                    ? t('discover.requested')
                    : t('discover.follow')
              }}</span>
            </Button>
          </div>
        </div>
        <p v-else class="py-4 text-center text-xs text-muted-foreground">
          {{ t('discover.emptyUsers') }}
        </p>
      </div>
    </section>

    <!-- Popular Groups Strip -->
    <section class="bento-card grid gap-3.5 p-5">
      <div class="flex items-center justify-between gap-2">
        <h2 class="flex items-center gap-2 text-sm font-semibold tracking-tight text-foreground">
          <Users class="size-4 text-primary" />
          <span>{{ t('discover.popularGroups') }}</span>
        </h2>
        <NuxtLink
          :to="localePath('/groups/discover')"
          class="inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline"
        >
          <span>{{ t('discover.viewAllGroups') }}</span>
          <ArrowRight class="size-3.5" />
        </NuxtLink>
      </div>

      <div v-if="!mounted || sectionLoading" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <Skeleton v-for="i in 3" :key="i" class="h-24 rounded-2xl" />
      </div>
      <div v-else-if="popularGroups.length" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <NuxtLink
          v-for="group in popularGroups"
          :key="group.id"
          :to="group.slug ? localePath(`/groups/${encodeURIComponent(group.slug)}`) : localePath('/groups/discover')"
          class="bento-tile pressable flex items-start gap-3 p-3.5 transition-colors hover:bg-accent"
        >
          <UserAvatar
            :src="group.avatar"
            :name="group.name"
            :seed="group.id"
            size="md"
          />
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-semibold text-foreground">
              {{ group.name }}
            </p>
            <p class="mt-0.5 line-clamp-1 text-xs text-muted-foreground">
              {{ group.description }}
            </p>
            <p class="mt-1.5 text-[11px] tabular-nums text-[var(--ink-tertiary)]">
              {{ t('discover.membersCount', { count: formatNumber(group.memberCount) }) }}
            </p>
          </div>
        </NuxtLink>
      </div>
      <p v-else class="py-4 text-center text-xs text-muted-foreground">
        {{ t('discover.emptyGroups') }}
      </p>
    </section>

    <!-- Trending Posts Feed -->
    <section class="space-y-3">
      <div class="flex items-center justify-between px-1">
        <h2 class="flex items-center gap-2 text-base font-semibold tracking-tight text-foreground">
          <Flame class="size-4 text-primary" />
          <span>{{ t('discover.trendingPosts') }}</span>
        </h2>
      </div>

      <Transition name="skeleton-crossfade" mode="out-in">
        <div v-if="!mounted || trendingFeed.loading" key="loading" class="space-y-3">
          <TweetCardSkeleton v-for="i in 4" :key="i" />
        </div>
        <div
          v-else-if="trendingFeed.error"
          key="error"
          class="bento-card flex items-center justify-between gap-3 px-4 py-4"
        >
          <p class="text-sm text-foreground">{{ t('post.feed.loadProblem') }}</p>
          <Button variant="secondary" size="sm" class="rounded-full" @click="trendingFeed.refresh()">
            {{ t('common.retry') }}
          </Button>
        </div>
        <AppEmptyState
          v-else-if="trendingFeed.posts.length === 0"
          key="empty"
          :icon="Flame"
          :title="t('discover.emptyPosts')"
          compact
        />
        <TweetList
          v-else
          key="posts"
          :tweets="trendingFeed.posts"
          class="px-0 py-0"
          @delete-tweet="actions.handleDeleteTweet"
          @reply-tweet="actions.handleReplyTweet"
          @retweet-tweet="actions.handleRetweetTweet"
          @like-tweet="actions.handleLikeTweet"
          @bookmark-tweet="actions.handleBookmarkTweet"
        />
      </Transition>

      <div
        v-if="!trendingFeed.loading && !trendingFeed.error && trendingFeed.totalPages > 1"
        class="flex items-center justify-center gap-3 py-4"
      >
        <Button
          variant="secondary"
          size="sm"
          class="rounded-full"
          :disabled="trendingFeed.page === 1"
          @click="goToPage(trendingFeed.page - 1)"
        >
          {{ t('common.prev') }}
        </Button>
        <span class="text-sm tabular-nums text-muted-foreground">
          {{ trendingFeed.page }} / {{ trendingFeed.totalPages }}
        </span>
        <Button
          variant="secondary"
          size="sm"
          class="rounded-full"
          :disabled="trendingFeed.page >= trendingFeed.totalPages"
          @click="goToPage(trendingFeed.page + 1)"
        >
          {{ t('common.next') }}
        </Button>
      </div>
    </section>

    <RetweetModal
      v-if="selectedTweetForRetweet"
      v-model:open="isRetweetModalOpen"
      :tweet="selectedTweetForRetweet"
      :is-submitting="isSubmittingRetweet"
      @submit-retweet="actions.handleSubmitRetweet"
    />
  </div>
</template>
