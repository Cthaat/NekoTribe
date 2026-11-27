<script setup lang="ts">
import { onMounted, onUnmounted, ref, computed, watch } from 'vue';
import { useNuxtApp } from '#app';
import { usePreferenceStore } from '@/stores/user';
import { authQueueFor } from '@/services/auth-request-queue';
import { setUserVisibility } from '@/api/v2/user-visibility';
import { v2ClearProfilePin, v2GetProfilePin, v2SetProfilePin } from '@/api/v2/profile-pinned-post';
import { mapPost } from '@/services/posts';
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
import { useRoute, useRouter } from 'vue-router';
import { ArrowLeft, Inbox, AlertTriangle } from 'lucide-vue-next';
import type { PostVM } from '@/types/posts';
import {
  v2BookmarkPost,
  v2DeletePost,
  v2FollowUser,
  v2GetUserById,
  v2LikePost,
  v2ListUserPosts,
  v2UnlikePost,
  v2UnbookmarkPost,
  v2UnfollowUser
} from '@/services';

const route = useRoute();
const router = useRouter();
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
  bio?: string;
  website?: string;
  verified?: boolean;
  postsCount?: number;
  stats: {
    followersCount: number;
    followingCount: number;
    likesCount: number;
  };
  point: number;
  onlineStatus: 'online' | 'offline' | 'hidden';
  lastSeenAt: string | null;
}

const user = ref<AccountHeaderUser>({
  id: 0,
  name: '',
  title: '',
  location: '',
  email: '',
  avatar: '',
  follow: 'unfollow',
  bio: '',
  website: '',
  verified: false,
  postsCount: 0,
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
const profilePostTab = ref<'posts' | 'replies' | 'media'>('posts');
const profileTabOrder: Array<'posts' | 'replies' | 'media'> = ['posts', 'replies', 'media'];
const profileTabPillStyle = computed(() => {
  const index = Math.max(0, profileTabOrder.indexOf(profilePostTab.value));
  const widthPct = 100 / profileTabOrder.length;
  return {
    left: `calc(${index * widthPct}% + 3px)`,
    width: `calc(${widthPct}% - 6px)`
  };
});

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
let tweetsLoad = 0;
let pinLoad = 0;
let relationshipIntent = 0;
let observedRevision = queue.revision;
const isCurrent = (id: number, revision: number) => !disposed && !queue.isIdentityChanging &&
  userId.value === id && queue.revision === revision;

function resetRelationship(): void {
  relationshipIntent++;
  user.value.point = 0;
  relationshipBusy.value = false;
  user.value.id = 0;
  user.value.bio = '';
  user.value.website = '';
  user.value.verified = false;
  user.value.postsCount = 0;
  blockedByViewer.value = false;
  blockedByTarget.value = false;
  blockDialogOpen.value = false;
  blockIntent = null;
  profileLoading.value = true;
  profileError.value = false;
  tweetsLoad++;
  pinLoad++;
  pinnedTweet.value = null;
  profilePinPending.value = false;
  tweetsLoading.value = false;
  tweetsError.value = null;
  fullTweets.value = [];
  totalTweetsCount.value = 0;
  profilePostTab.value = 'posts';
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
const pinnedTweet = ref<PostVM | null>(null);
const profilePinPending = ref(false);
const canManageProfilePin = computed(() => profileReady.value && preferenceStore.isLoggedIn &&
  preferenceStore.preferences.user.id === userId.value);
const visibleProfileTweets = computed(() => {
  const pin = pinnedTweet.value;
  const base = !pin || blockedByViewer.value || blockedByTarget.value
    ? fullTweets.value
    : (() => {
        const other = fullTweets.value.filter(tweet => tweet.id !== pin.id);
        return page.value === 1 ? [fullTweets.value.find(tweet => tweet.id === pin.id) ?? pin, ...other] : other;
      })();
  if (profilePostTab.value === 'replies') {
    return base.filter(tweet => tweet.replyToPostId !== null);
  }
  if (profilePostTab.value === 'media') {
    return base.filter(tweet => tweet.media.length > 0);
  }
  return base;
});
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
    user.value.bio = publicUser.bio;
    user.value.website = publicUser.website;
    user.value.verified = publicUser.verified;
    user.value.postsCount = publicUser.postsCount;
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

async function loadPinnedTweet() {
  const id = userId.value, revision = queue.revision, load = ++pinLoad;
  if (!profileReady.value || !isCurrent(id,revision)) return;
  const current = () => load === pinLoad && profileReady.value && isCurrent(id,revision);
  try {
    const pin = await app.runWithContext(() => v2GetProfilePin(id));
    if (current()) pinnedTweet.value = pin ? mapPost(pin) : null;
  } catch {
    if (current()) pinnedTweet.value = null;
  }
}

async function handleToggleProfilePin(tweet: PostVM) {
  const id = userId.value, revision = queue.revision;
  if (!canManageProfilePin.value || tweet.author.id !== id || profilePinPending.value || !isCurrent(id,revision)) return;
  const clear = pinnedTweet.value?.id === tweet.id;
  pinLoad++;
  profilePinPending.value = true;
  try {
    await app.runWithContext(() => clear ? v2ClearProfilePin() : v2SetProfilePin(tweet.id));
    if (!isCurrent(id,revision)) return;
    pinnedTweet.value = clear ? null : tweet;
    if (!clear) page.value = 1;
    toast.success(t(clear ? 'post.profilePin.cleared' : 'post.profilePin.saved'));
  } catch {
    if (isCurrent(id,revision)) toast.error(t('common.operationFailed'));
  } finally {
    if (isCurrent(id,revision)) profilePinPending.value = false;
  }
}

async function refreshProfilePage(): Promise<void> {
  if (!await loadUserProfile()) return;
  await Promise.all([
    loadTweets(),
    loadPinnedTweet()
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
    if (pinnedTweet.value?.id === tweetId) {
      pinLoad++;
      pinnedTweet.value = null;
    }
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

function updateProfileTweet(id: number, update: (tweet: PostVM) => PostVM) {
  fullTweets.value = fullTweets.value.map(tweet => tweet.id === id ? update(tweet) : tweet);
  if (pinnedTweet.value?.id === id) pinnedTweet.value = update(pinnedTweet.value);
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
    updateProfileTweet(tweet.id,currentTweet => ({
        ...currentTweet,
        viewer: {
          ...currentTweet.viewer,
          hasLiked: result.isLiked
        },
        counts: {
          ...currentTweet.counts,
          likes: result.likesCount
        }
    }));
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
    updateProfileTweet(tweet.id,currentTweet => ({
        ...currentTweet,
        viewer: {
          ...currentTweet.viewer,
          hasBookmarked: result.isBookmarked
        }
    }));
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
      pinLoad++;
      pinnedTweet.value = null;
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
  <div class="min-w-0">
    <header
      class="sticky top-0 z-20 flex h-14 items-center gap-3 bg-background/90 px-3 backdrop-blur-xl sm:px-0"
    >
      <button
        type="button"
        class="pressable inline-flex size-9 shrink-0 items-center justify-center rounded-full text-foreground transition-colors hover:bg-accent"
        :aria-label="t('common.back')"
        @click="router.back()"
      >
        <ArrowLeft class="size-5" />
      </button>
      <div class="min-w-0">
        <h1 class="truncate text-[18px] font-semibold tracking-tight text-foreground">
          {{ profileReady ? (user.name || `@${user.title}`) : t('nav.main.profile') }}
        </h1>
        <p v-if="profileReady" class="truncate text-xs text-[var(--ink-tertiary)]">
          {{ t('account.profileTabs.postsCount', { count: user.postsCount ?? totalTweetsCount }) }}
        </p>
      </div>
    </header>

    <div v-if="profileLoading && !profileReady" class="space-y-3 px-3 pt-2 sm:px-0">
      <div class="overflow-hidden rounded-[20px] bg-card">
        <div class="h-[116px] animate-pulse bg-secondary" />
        <div class="space-y-3 px-4 pb-5">
          <div class="-mt-10 size-20 animate-pulse rounded-full bg-secondary ring-4 ring-card" />
          <div class="h-5 w-40 animate-pulse rounded-lg bg-secondary" />
          <div class="h-4 w-28 animate-pulse rounded-lg bg-secondary" />
        </div>
      </div>
      <div class="space-y-3">
        <TweetCardSkeleton v-for="i in 3" :key="i" />
      </div>
    </div>

    <div v-else-if="profileError" class="px-3 pt-2 sm:px-0">
      <div class="grid justify-items-start gap-3 rounded-[20px] bg-card p-6">
        <p role="alert" class="text-sm text-destructive">{{ t('account.errors.loadUser') }}</p>
        <Button variant="secondary" size="sm" class="rounded-full" @click="refreshProfilePage">{{ t('common.retry') }}</Button>
      </div>
    </div>

    <template v-else-if="profileReady">
      <div class="px-3 pt-1 sm:px-0">
        <AccountHeaderCard
          social-mode
          :user="user"
          :account-tabs="localizedAccountTabs"
          v-model="activeTab"
          :interaction-blocked="blockedByViewer || blockedByTarget"
          :relationship-busy="relationshipBusy || changingIdentity"
          :visibility-actions="visibilityEnabled"
          :blocked-by-viewer="blockedByViewer"
          :analytics-available="false"
          @follow="followUser"
          @visibility="startVisibility"
          @refresh="refreshProfilePage"
        />
      </div>

      <Dialog v-model:open="blockDialogOpen">
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{{ t('visibility.block') }}</DialogTitle>
            <DialogDescription>{{ t('visibility.confirmBlock', { name: blockName }) }}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="secondary" class="rounded-full" @click="blockDialogOpen = false">{{ t('common.cancel') }}</Button>
            <Button variant="destructive" class="rounded-full" @click="confirmBlock">{{ t('visibility.block') }}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <!-- Capsule Segmented Tabs (Posts / Replies / Media) -->
      <div
        class="sticky top-14 z-10 bg-background/75 px-3 py-2.5 backdrop-blur-xl sm:px-0"
        role="tablist"
      >
        <div class="relative flex h-10 items-center rounded-full bg-secondary p-[3px]">
          <span
            aria-hidden="true"
            class="pointer-events-none absolute top-[3px] bottom-[3px] rounded-full bg-primary shadow-[0_2px_8px_rgba(0,122,255,0.28)] transition-[left,width] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] dark:shadow-none"
            :style="profileTabPillStyle"
          />
          <button
            v-for="tabKey in profileTabOrder"
            :key="tabKey"
            type="button"
            role="tab"
            :aria-selected="profilePostTab === tabKey"
            class="relative z-10 flex h-full flex-1 items-center justify-center rounded-full text-[13.5px] transition-colors"
            :class="profilePostTab === tabKey ? 'font-semibold text-primary-foreground' : 'font-medium text-muted-foreground hover:text-foreground'"
            @click="profilePostTab = tabKey"
          >
            {{ t(`account.profileTabs.${tabKey}`) }}
          </button>
        </div>
      </div>

      <section class="pb-10">
        <div v-if="tweetsLoading" class="space-y-3 px-3 py-2 sm:px-0">
          <TweetCardSkeleton v-for="i in 4" :key="i" />
        </div>

        <div v-else-if="tweetsError" class="px-3 py-2 sm:px-0">
          <div class="flex flex-col items-center justify-center gap-2 rounded-[20px] bg-card py-12 text-center">
            <span class="flex size-12 items-center justify-center rounded-full bg-rose-500/10">
              <AlertTriangle class="size-5 text-rose-500" />
            </span>
            <p class="text-sm text-rose-600 dark:text-rose-400">{{ tweetsError }}</p>
            <Button variant="secondary" size="sm" class="rounded-full" @click="loadTweets">{{ t('common.retry') }}</Button>
          </div>
        </div>

        <TweetList
          v-else-if="visibleProfileTweets.length > 0"
          :tweets="visibleProfileTweets"
          :pinned-post-id="pinnedTweet?.id"
          :can-manage-profile-pin="canManageProfilePin"
          :profile-pin-pending="profilePinPending"
          @delete-tweet="handleDeleteTweet"
          @reply-tweet="handleReplyTweet"
          @retweet-tweet="handleRetweetTweet"
          @like-tweet="handleLikeTweet"
          @bookmark-tweet="handleBookmarkTweet"
          @toggle-profile-pin="handleToggleProfilePin"
        />

        <div v-else class="px-3 py-2 sm:px-0">
          <div class="flex flex-col items-center justify-center gap-2 rounded-[20px] bg-card px-4 py-14 text-center">
            <span class="flex size-12 items-center justify-center rounded-full bg-secondary">
              <Inbox class="size-5 text-muted-foreground" />
            </span>
            <p class="text-sm text-muted-foreground">
              {{ t('post.feed.emptyUserPosts') }}
            </p>
          </div>
        </div>

        <div v-if="totalPages > 1" class="px-3 py-4 sm:px-0">
          <Pagination
            v-model:page="page"
            :items-per-page="pageSize"
            :total="totalTweetsCount"
            class="flex justify-center"
          >
            <PaginationContent v-slot="{ items }">
              <PaginationPrevious />
              <template v-for="(item, index) in items" :key="index">
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
    </template>
  </div>
</template>
