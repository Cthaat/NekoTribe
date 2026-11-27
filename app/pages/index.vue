<script lang="ts" setup>
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import { Info, Keyboard } from 'lucide-vue-next';
import { useStorage } from '@vueuse/core';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogTitle } from '@/components/ui/dialog';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import LiquidGlassIconButton from '@/components/glass/LiquidGlassIconButton.vue';
import LiquidGlassSegmented from '@/components/glass/LiquidGlassSegmented.vue';
import NewPostsPill from '@/components/motion/NewPostsPill.vue';
import { useScrollDirection } from '@/composables/useScrollDirection';
import { usePostFeed } from '@/composables/usePostFeed';
import { useTimelinePostActions } from '@/composables/useTimelinePostActions';
import { useTimelineShortcuts } from '@/composables/useTimelineShortcuts';
import { v2ListPosts, v2ListTrendingPosts } from '@/services/posts';
import { listHomeGroupActivity, setGroupPostLikeStatus } from '@/services/groups';
import type { HomeGroupPost } from '@/services/groups';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';

const tabs = ['recommended', 'following', 'trending', 'groups'] as const;
type HomeTab = typeof tabs[number];
function isTab(value: unknown): value is HomeTab {
  return tabs.some(candidate => candidate === value);
}

const route = useRoute();
const router = useRouter();
const localePath = useLocalePath();
const { t } = useAppLocale();
const app = useNuxtApp();
const account = usePreferenceStore();
const auth = authQueueFor(app);
const tab = computed(() => isTab(route.query.feed) ? route.query.feed : 'recommended');
const homeSegmentOptions = computed(() =>
  tabs.map(item => ({
    value: item,
    label: t(`post.feed.homeTab.${item}`)
  }))
);
const mounted = ref(false);
const generation = ref(0);
const pendingGroupLikes = shallowRef(new Set<number>());
const newPostsCount = ref(0);
const timeline = ref<HTMLElement | null>(null);
const shortcutHelpOpen = ref(false);
const timelineShortcutsEnabled = useStorage('nekotribe.timelineShortcuts', true);
useTimelineShortcuts(timeline, timelineShortcutsEnabled, {
  compose: () => { void navigateTo(localePath('/meow')); },
  help: () => { shortcutHelpOpen.value = true; }
});
const shortcutHelp = { J: 'next', K: 'previous', L: 'like', B: 'bookmark', R: 'reply', N: 'compose' };
const { scrollY, prefersReducedMotion } = useScrollDirection();

const posts = usePostFeed({ debugName: 'home-posts', loadPage: (page, pageSize) => app.runWithContext(() => {
  const view = tab.value;
  return view === 'trending' ? v2ListTrendingPosts({ page, pageSize }) :
    v2ListPosts({ page, pageSize, timeline: view === 'following' ? 'following' : 'recommended' });
}) });
const groups = usePostFeed({ debugName: 'home-groups', loadPage: (page, pageSize) =>
  app.runWithContext(() => listHomeGroupActivity(page, pageSize)),
});
const active = computed(() => tab.value === 'groups' ? groups : posts);
const actions = useTimelinePostActions(posts, () => String(generation.value));
const { isRetweetModalOpen, selectedTweetForRetweet, isSubmittingRetweet } = actions;

function refresh() {
  if (mounted.value && account.isLoggedIn && !auth.isIdentityChanging) void active.value.refresh();
}

function reset() {
  generation.value++;
  pendingGroupLikes.value = new Set();
  for (const feed of [posts, groups]) {
    feed.invalidate();
    feed.page = 1;
  }
}

function updateFeed() { reset(); refresh(); }

function selectTab(value: unknown) {
  if (!isTab(value) || value === tab.value) return;
  void router.replace({ query: { ...route.query, feed: value } });
}

function goToPage(page: number) {
  if (page < 1 || page > active.value.totalPages || active.value.loading) return;
  generation.value++;
  pendingGroupLikes.value = new Set();
  active.value.page = page;
  refresh();
}

function groupPostPath(post: HomeGroupPost) {
  return router.resolve({ path: localePath('/groups/posts'), query: { group: post.groupId, post: post.id } }).href;
}

async function shareGroupPost(post: HomeGroupPost) {
  const url = new URL(groupPostPath(post), window.location.origin).href;
  try {
    await navigator.clipboard.writeText(url);
    toast.success(t('groups.posts.shareCopied'));
  } catch { toast.info(url); }
}

async function likeGroupPost(post: HomeGroupPost) {
  if (pendingGroupLikes.value.has(post.id)) return;
  const pending = new Set(pendingGroupLikes.value).add(post.id);
  pendingGroupLikes.value = pending;
  const current = generation.value;
  try {
    const result = await setGroupPostLikeStatus(post.groupId, post.id, !post.isLiked);
    if (current !== generation.value) return;
    groups.patchPost(post.id, item => ({ ...item, isLiked: result.is_liked, likeCount: result.likes_count }));
  } catch {
    if (current === generation.value) toast.error(t('common.operationFailed'));
  } finally {
    if (current === generation.value) {
      const remaining = new Set(pendingGroupLikes.value);
      remaining.delete(post.id);
      pendingGroupLikes.value = remaining;
    }
  }
}

const showNewPostsPill = computed(() =>
  mounted.value &&
  !active.value.loading &&
  active.value.posts.length > 0 &&
  (newPostsCount.value > 0 || scrollY.value > 360)
);

function handlePillAction() {
  newPostsCount.value = 0;
  if (typeof window !== 'undefined') {
    window.scrollTo({
      top: 0,
      behavior: prefersReducedMotion.value ? 'auto' : 'smooth'
    });
  }
  refresh();
}

async function checkForNewPosts() {
  if (!mounted.value || !account.isLoggedIn || auth.isIdentityChanging || tab.value === 'groups') return;
  if (posts.page !== 1 || posts.loading || !posts.posts.length) return;
  const knownTopId = posts.posts[0]?.id;
  if (!knownTopId) return;
  try {
    const view = tab.value;
    const head = await app.runWithContext(() =>
      view === 'trending'
        ? v2ListTrendingPosts({ page: 1, pageSize: 5 })
        : v2ListPosts({ page: 1, pageSize: 5, timeline: view === 'following' ? 'following' : 'recommended' })
    );
    const newer = head.items.findIndex(item => item.id === knownTopId);
    if (newer > 0) {
      newPostsCount.value = newer;
    } else if (newer === -1 && head.items.length > 0 && head.items[0]!.id !== knownTopId) {
      newPostsCount.value = head.items.length;
    }
  } catch {
    // Non-blocking background check
  }
}

let unsubscribe: (() => void) | undefined;
function onVisibilityChange() {
  if (typeof document !== 'undefined' && document.visibilityState === 'visible') {
    void checkForNewPosts();
  }
}
watch([tab, () => account.isLoggedIn], () => {
  newPostsCount.value = 0;
  updateFeed();
}, { flush: 'sync' });
onMounted(() => {
  unsubscribe = auth.subscribe(updateFeed);
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange);
  }
  mounted.value = true;
  refresh();
});
onBeforeUnmount(() => {
  unsubscribe?.();
  if (typeof document !== 'undefined') {
    document.removeEventListener('visibilitychange', onVisibilityChange);
  }
  reset();
});
</script>

<template>
  <div class="min-w-0">
    <NewPostsPill
      :visible="showNewPostsPill"
      :count="newPostsCount"
      @click="handlePillAction"
    />
    <!-- Desktop quiet page header -->
    <div class="hidden items-center justify-between px-1 pt-4 pb-1 md:flex">
      <h1 class="text-[18px] font-semibold tracking-tight text-foreground">
        {{ t('nav.main.home') }}
      </h1>
      <LiquidGlassIconButton
        :aria-label="t('timelineShortcuts.title')"
        :title="t('timelineShortcuts.title')"
        aria-haspopup="dialog"
        @click="shortcutHelpOpen = true"
      >
        <Keyboard aria-hidden="true" class="size-4" />
      </LiquidGlassIconButton>
    </div>

    <!-- Capsule segmented timeline switcher -->
    <div class="sticky top-[54px] z-20 flex items-center gap-2 bg-background/75 px-3 pt-2.5 pb-2 backdrop-blur-xl md:top-0 md:px-0">
      <LiquidGlassSegmented
        :model-value="tab"
        :items="homeSegmentOptions"
        :aria-label="t('post.feed.homeTabs')"
        tone="primary"
        @update:model-value="selectTab"
      />

      <Popover v-if="tab === 'recommended'">
        <PopoverTrigger as-child>
          <LiquidGlassIconButton
            :aria-label="t('post.feed.infoTitle')"
            :title="t('post.feed.infoTitle')"
          >
            <Info class="size-4" />
          </LiquidGlassIconButton>
        </PopoverTrigger>
        <PopoverContent align="end" class="w-72 p-3.5 text-xs leading-[1.6]">
          <p class="mb-1 font-semibold text-foreground">{{ t('post.feed.infoTitle') }}</p>
          <p class="text-muted-foreground">{{ t('post.feed.rankingExplanation') }}</p>
        </PopoverContent>
      </Popover>
    </div>

    <div ref="timeline" class="min-w-0">
      <Transition name="skeleton-crossfade" mode="out-in">
        <div v-if="!mounted || active.loading" key="loading" class="space-y-3 px-3 py-2 sm:px-0" :aria-busy="true">
          <TweetCardSkeleton v-for="index in 5" :key="index" />
        </div>
        <div
          v-else-if="active.error"
          key="error"
          role="status"
          class="bento-card mx-3 my-2 flex items-center justify-between gap-3 px-4 py-4 sm:mx-0"
        >
          <p class="text-sm">{{ t('post.feed.loadProblem') }}</p>
          <Button variant="outline" size="sm" class="rounded-full" @click="refresh">{{ t('common.retry') }}</Button>
        </div>
        <div v-else-if="active.posts.length === 0" key="empty" class="px-4 py-12 text-center text-sm text-muted-foreground">
          {{ t(tab === 'groups' ? 'post.feed.emptyGroupActivity' : 'post.feed.emptyTitle') }}
        </div>
        <div v-else-if="tab === 'groups'" key="groups" class="space-y-3 px-3 py-2 sm:px-0">
          <article
            v-for="post in groups.posts"
            :key="post.id"
            data-timeline-post
            tabindex="-1"
            class="bento-card space-y-2 px-4 pt-4 pb-3 focus-visible:outline-2 focus-visible:outline-ring"
          >
            <NuxtLink :to="groupPostPath(post)" class="inline-block text-xs font-semibold text-primary hover:underline">
              {{ post.groupName }}
            </NuxtLink>
            <GroupPostCard
              :post="post" hide-menu :mutation-pending="pendingGroupLikes.has(post.id)"
              @comment="navigateTo(groupPostPath(post))" @share="shareGroupPost(post)" @like="likeGroupPost(post)" />
          </article>
        </div>
        <TweetList
          v-else key="posts" :tweets="posts.posts" keyboard-navigation
          @delete-tweet="actions.handleDeleteTweet" @reply-tweet="actions.handleReplyTweet"
          @retweet-tweet="actions.handleRetweetTweet" @like-tweet="actions.handleLikeTweet" @bookmark-tweet="actions.handleBookmarkTweet" />
      </Transition>

      <div v-if="!active.loading && !active.error && active.totalPages > 1" class="flex items-center justify-center gap-3 py-5">
        <Button variant="outline" size="sm" class="rounded-full" :disabled="active.page === 1" @click="goToPage(active.page - 1)">{{ t('common.prev') }}</Button>
        <span class="text-sm tabular-nums text-muted-foreground">{{ active.page }} / {{ active.totalPages }}</span>
        <Button variant="outline" size="sm" class="rounded-full" :disabled="active.page >= active.totalPages" @click="goToPage(active.page + 1)">{{ t('common.next') }}</Button>
      </div>
    </div>

    <RetweetModal
      v-if="selectedTweetForRetweet" v-model:open="isRetweetModalOpen"
      :tweet="selectedTweetForRetweet" :is-submitting="isSubmittingRetweet" @submit-retweet="actions.handleSubmitRetweet" />
    <Dialog v-model:open="shortcutHelpOpen">
      <DialogContent>
        <DialogTitle>{{ t('timelineShortcuts.title') }}</DialogTitle>
        <DialogDescription>{{ t('timelineShortcuts.description') }}</DialogDescription>
        <label class="flex items-center gap-2 text-sm">
          <input v-model="timelineShortcutsEnabled" type="checkbox" class="size-4 accent-primary">
          {{ t('timelineShortcuts.enabled') }}
        </label>
        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
          <template v-for="(label, key) in shortcutHelp" :key="key">
            <dt><kbd class="rounded border bg-muted px-1.5 py-0.5">{{ key }}</kbd></dt>
            <dd>{{ t(`timelineShortcuts.${label}`) }}</dd>
          </template>
        </dl>
      </DialogContent>
    </Dialog>
  </div>
</template>
