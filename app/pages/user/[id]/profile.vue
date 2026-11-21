<script setup lang="ts">
import { onMounted, onUnmounted, ref, computed, watch } from 'vue';
import { useNuxtApp } from '#app';
import { usePreferenceStore } from '@/stores/user';
import { authQueueFor } from '@/services/auth-request-queue';
import { setUserVisibility } from '@/api/v2/user-visibility';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import TweetList from '@/components/TweetList.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';
import { toast } from 'vue-sonner';
import { useRoute } from 'vue-router';
import { BarChart3, FileText, Inbox, AlertTriangle } from 'lucide-vue-next';
import type { PostVM } from '@/types/posts';
import {
  v2BookmarkPost,
  v2DeletePost,
  v2FollowUser,
  v2GetUserAnalytics,
  v2GetUserById,
  v2LikePost,
  v2ListUserPosts,
  v2UnlikePost,
  v2UnbookmarkPost,
  v2UnfollowUser
} from '@/services';

const route = useRoute();
const { t } = useAppLocale();
const localePath = useLocalePath();
const app = useNuxtApp();
const queue = authQueueFor(app);
const preferenceStore = usePreferenceStore();

interface AccountHeaderUser {
  id: number;
  name: string;
  title: string;
  location: string;
  email: string;
  avatar: string;
  follow: string;
  stats: {
    followersCount: number;
    followingCount: number;
    likesCount: number;
  };
  point: number;
  onlineStatus: 'online' | 'offline' | 'hidden';
  lastSeenAt: string | null;
}

interface UserAnalyticsData {
  totalTweets: number;
  tweetsThisWeek: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

const user = ref<AccountHeaderUser>({
  id: 0,
  name: '',
  title: '',
  location: '',
  email: '',
  avatar: '',
  follow: 'unfollow',
  stats: {
    followersCount: 0,
    followingCount: 0,
    likesCount: 0
  },
  point: 0,
  onlineStatus: 'hidden',
  lastSeenAt: null
});

const baseAccountTabs: Array<{ name: string; to: string }> = [];
const localizedAccountTabs = computed(() => {
  return baseAccountTabs.map(tab => ({
    name: t(tab.name),
    to: localePath(tab.to)
  }));
});
const activeTab = ref('Overview');

const userAnalytics = ref<UserAnalyticsData | null>(null);

const userId = computed(() => {
  const raw = route.params.id;
  if (typeof raw !== 'string' || !/^[1-9][0-9]{0,15}$/.test(raw) || raw.trim() !== raw) return 0;
  const id = Number(raw);
  return Number.isSafeInteger(id) ? id : 0;
});
const relationshipBusy = ref(false);
const blockedByViewer = ref(false);
const blockedByTarget = ref(false);
const changingIdentity = ref(queue.isIdentityChanging);
const profileLoading = ref(true);
const profileError = ref(false);
const profileReady = computed(() => !changingIdentity.value && user.value.id > 0 && user.value.id === userId.value);
const visibilityEnabled = computed(() => !changingIdentity.value && user.value.id === userId.value &&
  userId.value > 0 && preferenceStore.preferences.user.id > 0 && preferenceStore.preferences.user.id !== userId.value);
const blockDialogOpen = ref(false);
let blockIntent: { id: number; name: string; revision: number } | null = null;
const blockName = ref('');
let disposed = false;
let profileLoad = 0;
let analyticsLoad = 0;
let tweetsLoad = 0;
let relationshipIntent = 0;
let observedRevision = queue.revision;
const isCurrent = (id: number, revision: number) => !disposed && !queue.isIdentityChanging &&
  userId.value === id && queue.revision === revision;

function resetRelationship(): void {
  relationshipIntent++;
  analyticsLoad++;
  userAnalytics.value = null;
  user.value.point = 0;
  relationshipBusy.value = false;
  user.value.id = 0;
  blockedByViewer.value = false;
  blockedByTarget.value = false;
  blockDialogOpen.value = false;
  blockIntent = null;
  profileLoading.value = true;
  profileError.value = false;
  tweetsLoad++;
  tweetsLoading.value = false;
  tweetsError.value = null;
  fullTweets.value = [];
  totalTweetsCount.value = 0;
  page.value = 1;
}

const unsubscribe = queue.subscribe(() => {
  const settled = changingIdentity.value && !queue.isIdentityChanging;
  const changed = observedRevision !== queue.revision;
  changingIdentity.value = queue.isIdentityChanging;
  if (changed) {
    observedRevision = queue.revision;
    resetRelationship();
  }
  if ((changed || settled) && !queue.isIdentityChanging) {
    void refreshProfilePage();
  }
});
watch(blockDialogOpen, (open) => {
  if (!open) blockIntent = null;
}, { flush: 'sync' });
watch(userId, () => {
  resetRelationship();
  void refreshProfilePage();
}, { flush: 'sync' });
onUnmounted(() => { disposed = true; unsubscribe(); });

const page = ref(1);
const pageSize = ref(10);
const fullTweets = ref<PostVM[]>([]);
const tweetsLoading = ref(false);
const tweetsError = ref<string | null>(null);
const totalTweetsCount = ref(0);

const totalPages = computed(() =>
  Math.max(1, Math.ceil(totalTweetsCount.value / pageSize.value))
);

async function loadUserProfile(): Promise<boolean> {
  const id = userId.value;
  const revision = queue.revision;
  if (!isCurrent(id, revision)) return false;
  const load = ++profileLoad;
  profileLoading.value = true;
  profileError.value = false;
  try {
    if (!id) throw new Error('Invalid profile route');
    const publicUser = await app.runWithContext(() => v2GetUserById(id));
    if (!isCurrent(id, revision) || load !== profileLoad) return false;
    user.value.id = publicUser.id;
    user.value.name = publicUser.name;
    user.value.title = publicUser.username;
    user.value.location = publicUser.location;
    user.value.avatar = publicUser.avatarUrl;
    user.value.onlineStatus = publicUser.onlineStatus;
    user.value.lastSeenAt = publicUser.lastSeenAt;
    user.value.stats.followersCount =
      publicUser.followersCount;
    user.value.stats.followingCount =
      publicUser.followingCount;
    user.value.follow = publicUser.relationship.isFollowing
      ? 'follow'
      : 'unfollow';
    blockedByViewer.value = publicUser.relationship.isBlocking;
    blockedByTarget.value = publicUser.relationship.isBlocked;
    return true;
  } catch {
    if (isCurrent(id, revision) && load === profileLoad) {
      user.value.id = 0;
      profileError.value = true;
    }
    return false;
  } finally {
    if (isCurrent(id, revision) && load === profileLoad) profileLoading.value = false;
  }
}

async function loadUserAnalytics() {
  const id = userId.value;
  const revision = queue.revision;
  if (!isCurrent(id, revision)) return;
  const load = ++analyticsLoad;
  userAnalytics.value = null;
  user.value.point = 0;
  try {
    const analytics = await app.runWithContext(() => v2GetUserAnalytics(id));
    if (!isCurrent(id, revision) || load !== analyticsLoad) return;
    userAnalytics.value = {
      totalTweets: analytics.totalPosts,
      tweetsThisWeek: analytics.postsThisWeek,
      totalLikesReceived: analytics.totalLikesReceived,
      avgLikesPerTweet: analytics.avgLikesPerPost,
      totalLikesGiven: analytics.totalLikesGiven,
      totalCommentsMade: analytics.totalCommentsMade,
      engagementScore: analytics.engagementScore
    };
    user.value.stats.likesCount = analytics.totalLikesReceived;
    user.value.point = analytics.engagementScore;
  } catch {
    // An inaccessible profile has no analytics panel.
  }
}

async function loadTweets() {
  const id = userId.value;
  const revision = queue.revision;
  const requestedPage = page.value;
  if (!profileReady.value || !isCurrent(id, revision)) return;
  const load = ++tweetsLoad;
  const current = () => load === tweetsLoad && profileReady.value &&
    isCurrent(id, revision) && page.value === requestedPage;
  tweetsLoading.value = true;
  tweetsError.value = null;
  try {
    const result = await app.runWithContext(() => v2ListUserPosts(id, {
      page: requestedPage,
      pageSize: pageSize.value,
      sort: 'newest'
    }));
    if (!current()) return;
    fullTweets.value = result.items;
    totalTweetsCount.value = result.total;
  } catch (error) {
    if (!current()) return;
    tweetsError.value =
      error instanceof Error
        ? error.message
        : t('post.feed.loadFailed');
    fullTweets.value = [];
    totalTweetsCount.value = 0;
  } finally {
    if (current()) tweetsLoading.value = false;
  }
}

watch(page, () => {
  void loadTweets();
});

async function refreshProfilePage(): Promise<void> {
  if (!await loadUserProfile()) return;
  await Promise.all([
    loadUserAnalytics(),
    loadTweets()
  ]);
}

onMounted(() => {
  void refreshProfilePage();
});

async function handleDeleteTweet(tweetId: number) {
  try {
    await v2DeletePost(tweetId);
    toast.success(t('post.feedback.deleted'));
    fullTweets.value = fullTweets.value.filter(
      tweet => tweet.id !== tweetId
    );
    totalTweetsCount.value = Math.max(totalTweetsCount.value - 1, 0);
  } catch {
    toast.error(t('post.feedback.deleteFailed'));
  }
}

function handleReplyTweet(tweet: PostVM) {
  const detailPage = localePath(`/tweet/${tweet.id}`);
  return navigateTo(detailPage);
}

function handleRetweetTweet(tweet: PostVM) {
  const detailPage = localePath(`/tweet/${tweet.id}`);
  return navigateTo(detailPage);
}

async function handleLikeTweet(
  tweet: PostVM,
  action: 'like' | 'unlike'
) {
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweet.id)
        : await v2UnlikePost(tweet.id);
    const index = fullTweets.value.findIndex(
      item => item.id === tweet.id
    );
    if (index !== -1) {
      const currentTweet = fullTweets.value[index];
      if (!currentTweet) return;
      fullTweets.value[index] = {
        ...currentTweet,
        viewer: {
          ...currentTweet.viewer,
          hasLiked: result.isLiked
        },
        counts: {
          ...currentTweet.counts,
          likes: result.likesCount
        }
      };
    }
  } catch {
    toast.error(t('common.operationFailed'));
  }
}

async function handleBookmarkTweet(
  tweet: PostVM,
  action: 'mark' | 'unmark'
) {
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweet.id)
        : await v2UnbookmarkPost(tweet.id);
    const index = fullTweets.value.findIndex(
      item => item.id === tweet.id
    );
    if (index !== -1) {
      const currentTweet = fullTweets.value[index];
      if (!currentTweet) return;
      fullTweets.value[index] = {
        ...currentTweet,
        viewer: {
          ...currentTweet.viewer,
          hasBookmarked: result.isBookmarked
        }
      };
    }
  } catch {
    toast.error(t('common.operationFailed'));
  }
}

function goToPage(newPage: number) {
  if (newPage >= 1 && newPage <= totalPages.value) {
    page.value = newPage;
    if (import.meta.client) {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  }
}

async function followUser(targetUser: AccountHeaderUser, active: string) {
  const id = targetUser.id, revision = queue.revision, name = targetUser.name;
  if (id <= 0 || !isCurrent(id, revision) || relationshipBusy.value || blockedByViewer.value || blockedByTarget.value) return;
  const intent = ++relationshipIntent;
  relationshipBusy.value = true;
  try {
    const result =
      active === 'follow'
        ? await v2FollowUser(id)
        : await v2UnfollowUser(id);
    if (!isCurrent(id, revision) || intent !== relationshipIntent) return;
    profileLoad++;
    user.value.follow =
      result.relationship === 'following'
        ? 'follow'
        : 'unfollow';
    user.value.stats.followersCount = result.followersCount;
    toast.success(
      t(
        active === 'follow'
          ? 'account.follow.success'
          : 'account.follow.unfollowSuccess',
        { name }
      )
    );
  } catch {
    if (isCurrent(id, revision) && intent === relationshipIntent) toast.error(t('account.follow.failed'));
  } finally {
    if (isCurrent(id, revision) && intent === relationshipIntent) relationshipBusy.value = false;
  }
}

function startVisibility(action: 'block' | 'mute' | 'muteDay'): void {
  if (!visibilityEnabled.value || relationshipBusy.value) return;
  const target = { id: user.value.id, revision: queue.revision, name: user.value.name };
  if (action === 'block') {
    blockIntent = target;
    blockName.value = target.name;
    blockDialogOpen.value = true;
    return;
  }
  void applyVisibility(target, action);
}

function confirmBlock(): void {
  const target = blockIntent;
  blockIntent = null;
  blockDialogOpen.value = false;
  if (target) void applyVisibility(target, 'block');
}

async function applyVisibility(target: { id: number; revision: number }, action: 'block' | 'mute' | 'muteDay') {
  if (!visibilityEnabled.value || relationshipBusy.value || !isCurrent(target.id, target.revision)) return;
  const intent = ++relationshipIntent;
  relationshipBusy.value = true;
  try {
    const expiry = action === 'muteDay' ? new Date(Date.now() + 86_400_000).toISOString() : undefined;
    await setUserVisibility(action === 'block' ? 'blocks' : 'mutes', target.id, false, expiry);
    if (!isCurrent(target.id, target.revision) || intent !== relationshipIntent) return;
    profileLoad++;
    if (action === 'block') {
      analyticsLoad++;
      userAnalytics.value = null;
      user.value.point = 0;
      blockedByViewer.value = true;
      user.value.follow = 'unfollow';
      await loadUserProfile();
    }
    if (isCurrent(target.id, target.revision) && intent === relationshipIntent) toast.success(t('visibility.saved'));
  } catch {
    if (isCurrent(target.id, target.revision) && intent === relationshipIntent) toast.error(t('common.operationFailed'));
  } finally {
    if (isCurrent(target.id, target.revision) && intent === relationshipIntent) relationshipBusy.value = false;
  }
}
</script>

<template>
  <div class="grid gap-6 p-4 sm:p-6 lg:p-8">
    <p v-if="profileLoading && !profileReady" role="status">{{ t('common.loading') }}</p>
    <div v-else-if="profileError" class="grid justify-items-start gap-2 rounded-xl border p-5">
      <p role="alert">{{ t('account.errors.loadUser') }}</p>
      <Button variant="outline" @click="refreshProfilePage">{{ t('common.retry') }}</Button>
    </div>
    <AccountHeaderCard
      v-if="profileReady"
      :user="user"
      :account-tabs="localizedAccountTabs"
      v-model="activeTab"
      :interaction-blocked="blockedByViewer || blockedByTarget"
      :relationship-busy="relationshipBusy || changingIdentity"
      :visibility-actions="visibilityEnabled"
      :blocked-by-viewer="blockedByViewer"
      :analytics-available="userAnalytics !== null && !blockedByViewer && !blockedByTarget"
      @follow="followUser"
      @visibility="startVisibility"
      @refresh="refreshProfilePage"
    />
    <Dialog v-model:open="blockDialogOpen">
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{{ t('visibility.block') }}</DialogTitle>
          <DialogDescription>{{ t('visibility.confirmBlock', { name: blockName }) }}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" @click="blockDialogOpen = false">{{ t('common.cancel') }}</Button>
          <Button variant="destructive" @click="confirmBlock">{{ t('visibility.block') }}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <section
      v-if="profileReady && userAnalytics && !blockedByViewer && !blockedByTarget"
      class="grid gap-5 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
        >
          <BarChart3 class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('account.overview.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.overview.description') }}
          </p>
        </div>
      </header>
      <OverAllPanel :userAnalytics="userAnalytics" summary-only />
    </section>

    <section
      v-if="profileReady"
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
        >
          <FileText class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('post.feed.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{
              t('post.feed.total', {
                count: totalTweetsCount
              })
            }}
          </p>
        </div>
      </header>

      <div
        v-if="tweetsLoading"
        class="grid gap-3"
      >
        <TweetCardSkeleton v-for="i in 3" :key="i" />
      </div>

      <div
        v-else-if="tweetsError"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-rose-500/30 bg-rose-50/30 py-10 text-center dark:bg-rose-950/20"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 ring-1 ring-rose-500/20"
        >
          <AlertTriangle class="h-5 w-5 text-rose-500" />
        </span>
        <p class="text-sm text-rose-600 dark:text-rose-400">{{ tweetsError }}</p>
        <Button variant="outline" size="sm" @click="loadTweets">{{ t('common.retry') }}</Button>
      </div>

      <div v-else-if="fullTweets.length > 0">
        <TweetList
          :tweets="fullTweets"
          @delete-tweet="handleDeleteTweet"
          @reply-tweet="handleReplyTweet"
          @retweet-tweet="handleRetweetTweet"
          @like-tweet="handleLikeTweet"
          @bookmark-tweet="handleBookmarkTweet"
        />
      </div>

      <div
        v-else
        class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-10 text-center"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
        >
          <Inbox class="h-5 w-5 text-muted-foreground" />
        </span>
        <p class="text-sm text-muted-foreground">
          {{ t('post.feed.emptyUserPosts') }}
        </p>
      </div>

      <div v-if="totalPages > 1" class="pt-2">
        <Pagination
          v-model:page="page"
          :items-per-page="pageSize"
          :total="totalTweetsCount"
          class="flex justify-center"
        >
          <PaginationContent v-slot="{ items }">
            <PaginationPrevious />
            <template
              v-for="(item, index) in items"
              :key="index"
            >
              <PaginationItem
                v-if="item.type === 'page'"
                :value="item.value"
                :is-active="item.value === page"
              >
                {{ item.value }}
              </PaginationItem>
            </template>
            <PaginationNext />
          </PaginationContent>
        </Pagination>
      </div>
    </section>
  </div>
</template>
