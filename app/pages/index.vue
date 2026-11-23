<script lang="ts" setup>
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { usePostFeed } from '@/composables/usePostFeed';
import { useTimelinePostActions } from '@/composables/useTimelinePostActions';
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
const mounted = ref(false);
const generation = ref(0);
const pendingGroupLikes = shallowRef(new Set<number>());

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

let unsubscribe: (() => void) | undefined;
watch([tab, () => account.isLoggedIn], updateFeed, { flush: 'sync' });
onMounted(() => {
  unsubscribe = auth.subscribe(updateFeed);
  mounted.value = true;
  refresh();
});
onBeforeUnmount(() => { unsubscribe?.(); reset(); });
</script>

<template>
  <main class="mx-auto w-full max-w-2xl px-3 py-4 sm:px-4">
    <Tabs :model-value="tab" class="gap-4" @update:model-value="selectTab">
      <TabsList :aria-label="t('post.feed.homeTabs')" class="grid h-auto w-full grid-cols-4 p-1">
        <TabsTrigger v-for="item in tabs" :key="item" :value="item" class="min-h-9 px-2 text-sm">
          {{ t(`post.feed.homeTab.${item}`) }}
        </TabsTrigger>
      </TabsList>
      <TabsContent :value="tab" class="min-w-0 space-y-4">
        <p v-if="tab === 'recommended'" class="text-sm leading-relaxed text-muted-foreground">
          {{ t('post.feed.rankingExplanation') }}
        </p>
        <div v-if="!mounted || active.loading" class="space-y-3" :aria-busy="true">
          <TweetCardSkeleton v-for="index in 3" :key="index" />
        </div>
        <div v-else-if="active.error" role="status" class="flex items-center justify-between gap-3 rounded-lg border border-border px-4 py-3">
          <p class="text-sm">{{ t('post.feed.loadProblem') }}</p>
          <Button variant="outline" size="sm" @click="refresh">{{ t('common.retry') }}</Button>
        </div>
        <p v-else-if="active.posts.length === 0" class="rounded-lg border border-dashed border-border px-4 py-8 text-center text-sm text-muted-foreground">
          {{ t(tab === 'groups' ? 'post.feed.emptyGroupActivity' : 'post.feed.emptyTitle') }}
        </p>
        <div v-else-if="tab === 'groups'" class="space-y-4">
          <article v-for="post in groups.posts" :key="post.id" class="space-y-1.5">
            <NuxtLink :to="groupPostPath(post)" class="inline-block px-1 text-sm font-medium text-muted-foreground hover:text-foreground hover:underline">
              {{ post.groupName }}
            </NuxtLink>
            <GroupPostCard
              :post="post" hide-menu :mutation-pending="pendingGroupLikes.has(post.id)"
              @comment="navigateTo(groupPostPath(post))" @share="shareGroupPost(post)" @like="likeGroupPost(post)" />
          </article>
        </div>
        <TweetList
          v-else :tweets="posts.posts" @delete-tweet="actions.handleDeleteTweet" @reply-tweet="actions.handleReplyTweet"
          @retweet-tweet="actions.handleRetweetTweet" @like-tweet="actions.handleLikeTweet" @bookmark-tweet="actions.handleBookmarkTweet" />

        <div v-if="!active.loading && !active.error && active.totalPages > 1" class="flex items-center justify-center gap-3 pb-5">
          <Button variant="outline" size="sm" :disabled="active.page === 1" @click="goToPage(active.page - 1)">{{ t('common.prev') }}</Button>
          <span class="text-sm tabular-nums text-muted-foreground">{{ active.page }} / {{ active.totalPages }}</span>
          <Button variant="outline" size="sm" :disabled="active.page >= active.totalPages" @click="goToPage(active.page + 1)">{{ t('common.next') }}</Button>
        </div>
      </TabsContent>
    </Tabs>
    <RetweetModal
      v-if="selectedTweetForRetweet" v-model:open="isRetweetModalOpen"
      :tweet="selectedTweetForRetweet" :is-submitting="isSubmittingRetweet" @submit-retweet="actions.handleSubmitRetweet" />
  </main>
</template>
