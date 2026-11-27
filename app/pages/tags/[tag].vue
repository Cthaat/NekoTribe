<script lang="ts" setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { AlertTriangle, ArrowLeft, Compass, Feather, Hash } from 'lucide-vue-next';
import { v2GetTagAnalytics } from '@/api/v2/posts';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import RetweetModal from '@/components/RetweetModal.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import TweetList from '@/components/TweetList.vue';
import { Button } from '@/components/ui/button';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';
import { usePostFeed } from '@/composables/usePostFeed';
import { useTimelinePostActions } from '@/composables/useTimelinePostActions';
import { authQueueFor } from '@/services/auth-request-queue';
import { v2ListTagPosts } from '@/services/posts';
import { usePreferenceStore } from '@/stores/user';
import type { V2TagAnalytics } from '@/types/v2';

definePageMeta({
  layout: 'default'
});

const route = useRoute();
const localePath = useLocalePath();
const { t, locale } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const preferences = usePreferenceStore();

const hasMounted = ref(false);
const authChange = ref(0);
const tagStats = ref<V2TagAnalytics | null>(null);
const tagStatsRetry = ref(0);
const tagStatsFailed = ref(false);
let stopAuth: (() => void) | undefined;

const rawTag = computed(() => {
  const value = route.params.tag;
  const text = Array.isArray(value) ? String(value[0] ?? '') : typeof value === 'string' ? value : '';
  return text.replace(/^#+/, '').trim();
});

const tagMetrics = computed(() => {
  const stats = tagStats.value;
  if (!stats) return [];
  const format = new Intl.NumberFormat(locale.value === 'zh' ? 'zh-CN' : 'en-US', {
    maximumFractionDigits: 2
  });
  return [
    { key: 'posts', value: format.format(stats.total_posts) },
    { key: 'authors', value: format.format(stats.total_authors) },
    { key: 'views', value: format.format(stats.total_views) },
    { key: 'likes', value: format.format(stats.total_likes) },
    { key: 'engagement', value: format.format(stats.engagement_score) }
  ];
});

const feed = usePostFeed({
  debugName: 'tag-topic',
  pageSize: 15,
  loadPage: (page, pageSize) =>
    app.runWithContext(() => v2ListTagPosts(rawTag.value, page, pageSize))
});

const scopeKey = computed(() => `${rawTag.value}:${feed.page}:${authChange.value}`);
const actions = useTimelinePostActions(feed, () => scopeKey.value);
const { isRetweetModalOpen, selectedTweetForRetweet, isSubmittingRetweet } = actions;

watch(
  [hasMounted, rawTag, () => preferences.isLoggedIn, authChange, tagStatsRetry],
  async ([mounted, name, loggedIn], _, onCleanup) => {
    tagStats.value = null;
    tagStatsFailed.value = false;
    if (!mounted || !name || !loggedIn || auth.isIdentityChanging) return;
    let current = true;
    onCleanup(() => { current = false; });
    try {
      const stats = await app.runWithContext(() => v2GetTagAnalytics(name));
      if (current) tagStats.value = stats;
    } catch (error) {
      if (!current) return;
      const response = error as { statusCode?: number; response?: { status?: number } };
      tagStatsFailed.value = (response?.statusCode ?? response?.response?.status) !== 404;
    }
  },
  { flush: 'sync' }
);

watch(
  () => feed.page,
  () => {
    if (hasMounted.value && rawTag.value && preferences.isLoggedIn && !auth.isIdentityChanging) {
      void feed.refresh();
    }
  },
  { flush: 'sync' }
);

watch(
  [rawTag, authChange, () => preferences.isLoggedIn],
  () => {
    if (!hasMounted.value) return;
    feed.invalidate();
    if (feed.page !== 1) {
      feed.page = 1;
      return;
    }
    if (rawTag.value && preferences.isLoggedIn && !auth.isIdentityChanging) {
      void feed.refresh();
    }
  },
  { flush: 'sync' }
);

onMounted(() => {
  stopAuth = auth.subscribe(() => { authChange.value++; });
  hasMounted.value = true;
  if (rawTag.value && preferences.isLoggedIn && !auth.isIdentityChanging) {
    void feed.refresh();
  }
});

onBeforeUnmount(() => {
  stopAuth?.();
  feed.invalidate();
});
</script>

<template>
  <div class="mx-auto w-full max-w-[640px] space-y-4 px-3 py-4 pb-10 sm:px-0">
    <!-- Topic Header Card -->
    <section class="bento-card grid gap-4 p-5">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex min-w-0 items-center gap-3">
          <NuxtLink
            :to="localePath('/discover')"
            class="pressable inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-secondary text-foreground transition-colors hover:bg-accent"
            :aria-label="t('tags.backToDiscover')"
          >
            <ArrowLeft class="size-4" />
          </NuxtLink>
          <div class="min-w-0">
            <h1 class="flex items-center gap-1 truncate text-xl font-semibold tracking-tight text-foreground">
              <Hash class="size-5 shrink-0 text-primary" />
              <span class="truncate">{{ rawTag }}</span>
            </h1>
            <p class="truncate text-xs text-muted-foreground">
              {{ t('tags.subtitle', { tag: rawTag }) }}
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <Button variant="secondary" size="sm" as-child class="pressable rounded-full px-3.5">
            <NuxtLink :to="localePath('/discover')">
              <Compass class="size-3.5" />
              <span>{{ t('tags.backToDiscover') }}</span>
            </NuxtLink>
          </Button>
          <Button size="sm" as-child class="pressable rounded-full px-3.5">
            <NuxtLink :to="localePath(`/meow?tag=${encodeURIComponent(rawTag)}`)">
              <Feather class="size-3.5" />
              <span>{{ t('tags.composeWithTag') }}</span>
            </NuxtLink>
          </Button>
        </div>
      </div>

      <dl v-if="tagStats" class="grid grid-cols-2 gap-2.5 sm:grid-cols-5">
        <div
          v-for="metric in tagMetrics"
          :key="metric.key"
          class="bento-tile px-3 py-2.5"
        >
          <dt class="text-[11px] text-muted-foreground">
            {{ t(`tags.metrics.${metric.key}`) }}
          </dt>
          <dd class="mt-0.5 text-base font-semibold tabular-nums text-foreground">
            {{ metric.value }}
          </dd>
        </div>
      </dl>
      <button
        v-else-if="tagStatsFailed"
        type="button"
        class="w-fit text-xs font-medium text-primary hover:underline"
        @click="tagStatsRetry++"
      >
        {{ t('post.tagAnalytics.retry') }}
      </button>
    </section>

    <!-- Topic Feed -->
    <Transition name="skeleton-crossfade" mode="out-in">
      <div v-if="!hasMounted || feed.loading" key="loading" class="space-y-3">
        <TweetCardSkeleton v-for="i in 5" :key="i" />
      </div>

      <div
        v-else-if="feed.error"
        key="error"
        class="bento-card flex flex-col items-center justify-center gap-3 py-12 text-center"
      >
        <span class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 text-rose-500">
          <AlertTriangle class="h-5 w-5" />
        </span>
        <p class="text-sm font-medium">{{ t('post.feed.loadProblem') }}</p>
        <p class="max-w-md px-4 text-xs text-muted-foreground">{{ feed.error }}</p>
        <Button variant="secondary" size="sm" class="rounded-full" @click="feed.refresh()">
          {{ t('common.retry') }}
        </Button>
      </div>

      <TweetList
        v-else-if="feed.posts.length > 0"
        key="posts"
        :tweets="feed.posts"
        class="px-0 py-0"
        @delete-tweet="actions.handleDeleteTweet"
        @reply-tweet="actions.handleReplyTweet"
        @retweet-tweet="actions.handleRetweetTweet"
        @like-tweet="actions.handleLikeTweet"
        @bookmark-tweet="actions.handleBookmarkTweet"
      />

      <AppEmptyState
        v-else
        key="empty"
        :icon="Hash"
        :title="t('tags.emptyPosts')"
        :description="t('post.feed.searchEmptyDescription')"
      />
    </Transition>

    <Pagination
      v-if="!feed.loading && !feed.error && feed.total > 0"
      v-model:page="feed.page"
      :items-per-page="feed.pageSize"
      :total="feed.total"
      class="flex justify-center py-4"
    >
      <PaginationContent v-slot="{ items }">
        <PaginationPrevious />
        <template v-for="(item, index) in items" :key="index">
          <PaginationItem
            v-if="item.type === 'page'"
            :value="item.value"
            :is-active="item.value === feed.page"
          >
            {{ item.value }}
          </PaginationItem>
        </template>
        <PaginationNext />
      </PaginationContent>
    </Pagination>

    <RetweetModal
      v-if="selectedTweetForRetweet"
      v-model:open="isRetweetModalOpen"
      :tweet="selectedTweetForRetweet"
      :is-submitting="isSubmittingRetweet"
      @submit-retweet="actions.handleSubmitRetweet"
    />
  </div>
</template>
