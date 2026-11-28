<script setup lang="ts">
import {
  computed,
  onUnmounted,
  ref,
  watch
} from 'vue';
import AvatarUploader from '@/components/AvatarUploader.vue';
import { authQueueFor } from '@/services/auth-request-queue';
import { useNuxtApp } from '#app';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Label } from '@/components/ui/label';
import { Progress } from '@/components/ui/progress';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Tabs,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import {
  AlertTriangle,
  BadgeCheck,
  Copy,
  ExternalLink,
  Heart,
  Inbox,
  Link2,
  Loader2,
  Mail,
  MapPin,
  MessageCircle,
  MoreHorizontal,
  RefreshCw,
  Settings,
  Shield,
  User,
  UserRound,
  Users
} from 'lucide-vue-next';
import UserAvatar from '@/components/UserAvatar.vue';
import AnimatedNumber from '@/components/motion/AnimatedNumber.vue';
import type { PropType } from 'vue';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '~/stores/user';
import {
  v2GetUserAnalytics,
  v2ListUserFollowers,
  v2ListUserFollowing
} from '@/services';
import type {
  PublicUserVM,
  UserAnalyticsVM
} from '@/types/users';

const preferenceStore = usePreferenceStore();
const queue = authQueueFor(useNuxtApp());
const { t, locale } = useAppLocale();
const localePath = useLocalePath();

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

interface UserData {
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

interface TabItem {
  name: string;
  to: string;
}

const props = defineProps({
  user: {
    type: Object as PropType<UserData>,
    required: true
  },
  accountTabs: {
    type: Array as PropType<TabItem[]>,
    required: true
  },
  interactionBlocked: Boolean,
  relationshipBusy: Boolean,
  visibilityActions: Boolean,
  blockedByViewer: Boolean,
  analyticsAvailable: { type: Boolean, default: true },
  socialMode: { type: Boolean, default: false }
});

const followHovered = ref(false);

const emit = defineEmits<{
  (e: 'update:user', user: UserData): void;
  (
    e: 'follow',
    user: UserData,
    action: 'follow' | 'unfollow'
  ): void;
  (e: 'refresh'): void;
  (e: 'visibility', action: 'block' | 'mute' | 'muteDay'): void;
}>();

type StatsDialogType = 'followers' | 'following' | 'likes';

const STATS_PAGE_SIZE = 20;

const statsDialogOpen = ref(false);
const activeStatsType =
  ref<StatsDialogType>('followers');
const relationshipUsers = ref<PublicUserVM[]>([]);
const relationshipTotal = ref(0);
const relationshipPage = ref(1);
const relationshipHasNext = ref(false);
const relationshipLoading = ref(false);
const relationshipError = ref<string | null>(null);
const likesAnalytics = ref<UserAnalyticsVM | null>(null);
const likesLoading = ref(false);
const likesError = ref<string | null>(null);

const handleAvatarUpdate = (
  newAvatarRelativePath: string
) => {
  const updatedUser = { ...props.user };
  updatedUser.avatar = newAvatarRelativePath;
  emit('update:user', updatedUser);
};

const avatarUploaderProps = computed(() => ({
  name: props.user.name,
  avatar: props.user.avatar
}));

const MAX_POSSIBLE_SCORE = 3000;

const normalizedScore = computed(() => {
  const originalScore = props.user.point;
  const minScore = 0;

  let score_0_to_100 =
    ((originalScore - minScore) /
      (MAX_POSSIBLE_SCORE - minScore)) *
    100;

  score_0_to_100 = Math.max(
    0,
    Math.min(score_0_to_100, 100)
  );

  return score_0_to_100;
});

const tabValue = defineModel<string>();
const route = useRoute();

const currentUserId = computed(
  () => preferenceStore.preferences.user.id
);

const isSelfProfile = computed(() => {
  return props.user.id > 0 && props.user.id === currentUserId.value;
});

let likesLoad = 0;
function clearLikesAnalytics() {
  likesLoad++;
  likesAnalytics.value = null;
  likesError.value = null;
  likesLoading.value = false;
  if (activeStatsType.value === 'likes') statsDialogOpen.value = false;
}
watch(() => [props.user.id, currentUserId.value, props.interactionBlocked, props.analyticsAvailable], clearLikesAnalytics, { flush: 'sync' });
let likesRevision = queue.revision;
const unsubscribeLikes = queue.subscribe(() => {
  if (queue.revision !== likesRevision || queue.isIdentityChanging) clearLikesAnalytics();
  likesRevision = queue.revision;
});
onUnmounted(() => { likesLoad++; unsubscribeLikes(); });

const statsDialogTitle = computed(() => {
  if (activeStatsType.value === 'followers') {
    return t('account.stats.followersTitle');
  }
  if (activeStatsType.value === 'following') {
    return t('account.stats.followingTitle');
  }
  return t('account.stats.likesTitle');
});

const statsDialogDescription = computed(() => {
  if (activeStatsType.value === 'followers') {
    return t('account.stats.followersDescription');
  }
  if (activeStatsType.value === 'following') {
    return t('account.stats.followingDescription');
  }
  return t('account.stats.likesDescription');
});

const likesStatItems = computed(() => {
  const analytics = likesAnalytics.value;

  return [
    {
      label: t('account.stats.totalLikesReceived'),
      value: formatNumber(
        analytics?.totalLikesReceived ??
          props.user.stats.likesCount
      )
    },
    {
      label: t('account.stats.avgLikesPerPost'),
      value: formatDecimal(analytics?.avgLikesPerPost ?? 0)
    },
    ...(isSelfProfile.value ? [
      { label: t('account.stats.totalLikesGiven'), value: formatNumber(analytics?.totalLikesGiven ?? 0) },
      { label: t('account.stats.totalCommentsMade'), value: formatNumber(analytics?.totalCommentsMade ?? 0) }
    ] : []),
    {
      label: t('account.stats.postsCount'),
      value: formatNumber(analytics?.totalPosts ?? 0)
    },
    {
      label: t('account.stats.engagementScore'),
      value: formatNumber(
        analytics?.engagementScore ?? props.user.point
      )
    }
  ];
});

function formatNumber(value: number): string {
  return new Intl.NumberFormat(
    locale.value === 'en' ? 'en-US' : 'zh-CN'
  ).format(value);
}

function formatDecimal(value: number): string {
  return new Intl.NumberFormat(
    locale.value === 'en' ? 'en-US' : 'zh-CN',
    {
      maximumFractionDigits: 1
    }
  ).format(value);
}

function getUserInitials(user: PublicUserVM): string {
  return (
    user.name ||
    user.username ||
    '?'
  )
    .trim()
    .slice(0, 1)
    .toUpperCase();
}

function getProfilePath(userId: number): string {
  return localePath(`/user/${userId}/profile`);
}

function onlineStatusLabel(
  status: UserData['onlineStatus']
): string {
  return status === 'online'
    ? t('chat.status.online')
    : t('chat.status.offline');
}

function onlineStatusClass(
  status: UserData['onlineStatus']
): string {
  return status === 'online'
    ? 'bg-[var(--status-online-fg)]'
    : 'bg-muted-foreground';
}

function formatLastSeen(value: string | null): string {
  if (!value) return '';
  return new Date(value).toLocaleString(
    locale.value === 'en' ? 'en-US' : 'zh-CN',
    {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    }
  );
}

function openUserProfile(userId: number): void {
  if (userId <= 0) return;
  void navigateTo(getProfilePath(userId));
}

function openPublicProfile(): void {
  openUserProfile(props.user.id);
}

async function copyProfileLink(): Promise<void> {
  if (!import.meta.client || props.user.id <= 0) return;

  try {
    const url = new URL(
      getProfilePath(props.user.id),
      window.location.origin
    ).toString();
    await navigator.clipboard.writeText(url);
    toast.success(t('account.actions.copied'));
  } catch {
    toast.error(t('common.operationFailed'));
  }
}

function refreshProfile(): void {
  emit('refresh');
}

function goToAccountSettings(): void {
  void navigateTo(localePath('account-settings'));
}

function goToAccountSecurity(): void {
  void navigateTo(localePath('account-security'));
}

function openDirectMessage(): void {
  if (props.user.id <= 0 || isSelfProfile.value || props.interactionBlocked || props.relationshipBusy) return;
  void navigateTo(localePath(`/chat?dm=${props.user.id}`));
}

async function loadRelationshipUsers(
  reset = true
): Promise<void> {
  if (props.user.id <= 0 || relationshipLoading.value) return;

  relationshipLoading.value = true;
  relationshipError.value = null;

  try {
    const nextPage = reset
      ? 1
      : relationshipPage.value + 1;
    const result =
      activeStatsType.value === 'followers'
        ? await v2ListUserFollowers(props.user.id, {
            page: nextPage,
            pageSize: STATS_PAGE_SIZE
          })
        : await v2ListUserFollowing(props.user.id, {
            page: nextPage,
            pageSize: STATS_PAGE_SIZE
          });

    relationshipUsers.value = reset
      ? result.items
      : [...relationshipUsers.value, ...result.items];
    relationshipTotal.value = result.total;
    relationshipPage.value = result.page;
    relationshipHasNext.value = result.hasNext;
  } catch {
    relationshipError.value = t('account.stats.loadFailed');
  } finally {
    relationshipLoading.value = false;
  }
}

async function loadLikesAnalytics(): Promise<void> {
  const id = props.user.id;
  if (id <= 0 || !props.analyticsAvailable || likesLoading.value || queue.isIdentityChanging) return;
  const load = ++likesLoad;

  likesLoading.value = true;
  likesError.value = null;

  try {
    const analytics = await v2GetUserAnalytics(id);
    if (load === likesLoad) likesAnalytics.value = analytics;
  } catch {
    if (load === likesLoad) likesError.value = t('account.stats.loadFailed');
  } finally {
    if (load === likesLoad) likesLoading.value = false;
  }
}

function openStatsDialog(type: StatsDialogType): void {
  activeStatsType.value = type;
  statsDialogOpen.value = true;

  if (type === 'likes') {
    void loadLikesAnalytics();
    return;
  }

  relationshipUsers.value = [];
  relationshipTotal.value = 0;
  relationshipPage.value = 1;
  relationshipHasNext.value = false;
  void loadRelationshipUsers(true);
}

function normalizePath(path: string): string {
  return path.replace(/\/+$/, '') || '/';
}

function isTabActive(tab: TabItem): boolean {
  return normalizePath(route.path) === normalizePath(tab.to);
}

function syncActiveTabFromRoute(): void {
  const active = props.accountTabs.find(isTabActive);
  if (active) {
    tabValue.value = active.name;
  }
}

function selectTab(tab: TabItem): void {
  tabValue.value = tab.name;
}

function handleTabChange(value: string | number): void {
  const selectedName = String(value);
  const selectedTab = props.accountTabs.find(
    tab => tab.name === selectedName
  );
  if (!selectedTab) return;
  selectTab(selectedTab);
  void navigateTo(selectedTab.to);
}

const isFollowing = computed(() => props.user.follow === 'follow');
const showFollowAction = computed(() => {
  return props.user.id > 0 && props.user.id !== currentUserId.value && !props.interactionBlocked;
});

watch(
  () => [route.path, props.accountTabs] as const,
  syncActiveTabFromRoute,
  { immediate: true }
);

function followUser() {
  if (props.interactionBlocked || props.relationshipBusy) return;
  if (
    props.user.id ===
    preferenceStore.preferences.user.id
  ) {
    toast.error(t('account.header.selfFollowError'));
    return;
  }
  if (isFollowing.value) {
    emit('follow', props.user, 'unfollow');
  } else {
    emit('follow', props.user, 'follow');
  }
}
</script>

<template>
  <!-- Quiet Tonal Bento profile card -->
  <section
    v-if="socialMode"
    class="bento-card overflow-hidden"
  >
    <div class="h-[116px] w-full bg-secondary bg-subtle-grid" />

    <div class="px-4 pb-5">
      <div class="-mt-10 mb-3 flex items-end justify-between gap-3">
        <div class="relative inline-flex shrink-0 rounded-full bg-card ring-4 ring-card">
          <UserAvatar
            :src="user.avatar"
            :name="user.name"
            :username="user.title"
            :seed="user.id"
            size="xl"
          />
          <span
            v-if="user.onlineStatus === 'online'"
            :title="onlineStatusLabel(user.onlineStatus)"
            class="absolute right-1 bottom-1 size-3.5 rounded-full bg-[var(--status-online-fg)] ring-2 ring-card"
          />
        </div>

        <div class="flex flex-wrap items-center gap-2 pt-12">
          <NuxtLink
            v-if="isSelfProfile"
            :to="localePath('/account/profile')"
            class="pressable inline-flex h-9 items-center rounded-full bg-secondary px-4 text-sm font-semibold text-foreground transition-colors hover:bg-accent"
          >
            {{ t('account.profileTabs.editProfile') }}
          </NuxtLink>
          <template v-else-if="showFollowAction">
            <Button
              variant="secondary"
              size="icon"
              class="pressable size-9 rounded-full border-0 bg-secondary text-foreground hover:bg-accent"
              :title="t('account.actions.directMessage')"
              :aria-label="t('account.actions.directMessage')"
              :disabled="relationshipBusy"
              @click="openDirectMessage"
            >
              <MessageCircle class="size-4" />
            </Button>
            <Button
              v-if="!isFollowing"
              size="sm"
              class="pressable h-9 rounded-full px-5 font-semibold"
              :disabled="relationshipBusy"
              @click="followUser"
            >
              {{ t('account.header.follow') }}
            </Button>
            <Button
              v-else
              variant="secondary"
              size="sm"
              class="pressable h-9 rounded-full border-0 px-5 font-semibold transition-colors"
              :class="followHovered ? 'bg-destructive/10 text-destructive hover:bg-destructive/15' : 'bg-secondary text-foreground hover:bg-accent'"
              :disabled="relationshipBusy"
              @mouseenter="followHovered = true"
              @mouseleave="followHovered = false"
              @click="followUser"
            >
              {{ t(followHovered ? 'account.profileTabs.unfollowHover' : 'account.profileTabs.followingLabel') }}
            </Button>
          </template>

          <DropdownMenu>
            <DropdownMenuTrigger as-child>
              <Button
                variant="secondary"
                size="icon"
                class="size-9 shrink-0 rounded-full border-0 bg-secondary text-muted-foreground hover:bg-accent hover:text-foreground"
              >
                <MoreHorizontal class="size-4" />
                <span class="sr-only">
                  {{ t('account.header.moreActions') }}
                </span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" class="w-52 rounded-2xl p-1.5">
              <DropdownMenuItem @click="copyProfileLink">
                <Copy class="h-4 w-4" />
                {{ t('account.actions.copyProfileLink') }}
              </DropdownMenuItem>
              <DropdownMenuItem
                v-if="showFollowAction"
                :disabled="relationshipBusy"
                @click="openDirectMessage"
              >
                <MessageCircle class="h-4 w-4" />
                {{ t('account.actions.directMessage') }}
              </DropdownMenuItem>
              <template v-if="visibilityActions">
                <DropdownMenuSeparator />
                <DropdownMenuItem :disabled="relationshipBusy" @select="emit('visibility', 'muteDay')">
                  {{ t('visibility.muteDay') }}
                </DropdownMenuItem>
                <DropdownMenuItem :disabled="relationshipBusy" @select="emit('visibility', 'mute')">
                  {{ t('visibility.mute') }}
                </DropdownMenuItem>
                <DropdownMenuItem v-if="!blockedByViewer" :disabled="relationshipBusy" @select="emit('visibility', 'block')">
                  {{ t('visibility.block') }}
                </DropdownMenuItem>
              </template>
              <DropdownMenuItem @click="refreshProfile">
                <RefreshCw class="h-4 w-4" />
                {{ t('account.actions.refreshProfile') }}
              </DropdownMenuItem>
              <DropdownMenuSeparator v-if="isSelfProfile" />
              <DropdownMenuItem
                v-if="isSelfProfile"
                @click="goToAccountSettings"
              >
                <Settings class="h-4 w-4" />
                {{ t('account.actions.accountSettings') }}
              </DropdownMenuItem>
              <DropdownMenuItem
                v-if="isSelfProfile"
                @click="goToAccountSecurity"
              >
                <Shield class="h-4 w-4" />
                {{ t('account.actions.securitySettings') }}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      <div class="space-y-2.5">
        <div>
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="truncate text-[18px] font-semibold leading-tight tracking-tight text-foreground">
              {{ user.name || user.title }}
            </h2>
            <BadgeCheck v-if="user.verified" class="size-[18px] shrink-0 text-primary" />
            <span
              v-if="user.onlineStatus === 'online'"
              class="status-pill-online inline-flex items-center gap-1.5 px-2.5 py-0.5 text-[11px] font-semibold"
            >
              <span class="size-1.5 rounded-full bg-[var(--status-online-fg)]" />
              {{ onlineStatusLabel(user.onlineStatus) }}
            </span>
          </div>
          <p v-if="user.title" class="mt-0.5 text-[13.5px] text-[var(--ink-tertiary)]">
            @{{ user.title }}
          </p>
        </div>

        <p v-if="user.bio" class="whitespace-pre-wrap text-[15px] leading-[1.6] text-foreground">
          {{ user.bio }}
        </p>

        <div
          v-if="user.location || user.website"
          class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-muted-foreground"
        >
          <span v-if="user.location" class="inline-flex items-center gap-1">
            <MapPin class="size-3.5" />
            <span>{{ user.location }}</span>
          </span>
          <span v-if="user.website" class="inline-flex items-center gap-1">
            <Link2 class="size-3.5" />
            <span class="max-w-[260px] truncate">{{ user.website }}</span>
          </span>
        </div>

        <div class="flex flex-wrap items-center gap-5 pt-0.5 text-sm">
          <button
            type="button"
            class="inline-flex items-baseline gap-1 hover:underline"
            @click="openStatsDialog('following')"
          >
            <strong class="font-semibold text-foreground">
              <AnimatedNumber :value="user.stats.followingCount" />
            </strong>
            <span class="text-muted-foreground">{{ t('account.header.following') }}</span>
          </button>
          <button
            type="button"
            class="inline-flex items-baseline gap-1 hover:underline"
            @click="openStatsDialog('followers')"
          >
            <strong class="font-semibold text-foreground">
              <AnimatedNumber :value="user.stats.followersCount" />
            </strong>
            <span class="text-muted-foreground">{{ t('account.header.followers') }}</span>
          </button>
        </div>
      </div>
    </div>
  </section>

  <!-- Account management bento card (used by /account/*) -->
  <section
    v-else
    class="bento-card mobile-scroll-safe p-5 sm:p-6"
  >
    <div class="flex flex-col items-stretch gap-5 sm:flex-row sm:items-start sm:gap-6">
      <div class="relative shrink-0 self-start">
        <AvatarUploader
          :user="avatarUploaderProps"
          @update:avatar="handleAvatarUpdate"
        />
        <span
          :title="onlineStatusLabel(user.onlineStatus)"
          class="absolute right-0.5 bottom-0.5 size-3.5 rounded-full ring-2 ring-card"
          :class="onlineStatusClass(user.onlineStatus)"
        />
      </div>

      <div class="w-full min-w-0 flex-1 space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0 space-y-1.5">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <h2 class="min-w-0 truncate text-lg font-semibold tracking-tight">
                  {{ user.name }}
                </h2>
                <span
                  v-if="user.onlineStatus === 'online'"
                  class="status-pill-online inline-flex items-center gap-1.5 px-2.5 py-0.5 text-[11px] font-semibold"
                >
                  <span class="size-1.5 rounded-full bg-[var(--status-online-fg)]" />
                  {{ onlineStatusLabel(user.onlineStatus) }}
                </span>
              </div>
              <div
                class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-[var(--ink-tertiary)]"
              >
                <span
                  v-if="user.title"
                  class="flex min-w-0 items-center gap-1.5"
                >
                  <User class="h-3.5 w-3.5" />
                  <span class="min-w-0 truncate">@{{ user.title }}</span>
                </span>
                <span
                  v-if="user.location"
                  class="flex min-w-0 items-center gap-1.5"
                >
                  <MapPin class="h-3.5 w-3.5" />
                  <span class="min-w-0 truncate">{{ user.location }}</span>
                </span>
                <span
                  v-if="user.email"
                  class="flex min-w-0 max-w-full items-center gap-1.5"
                >
                  <Mail class="h-3.5 w-3.5 shrink-0" />
                  <span class="min-w-0 truncate">{{ user.email }}</span>
                </span>
              </div>
            </div>
            <div class="mobile-action-row w-full self-start sm:w-auto sm:flex-nowrap sm:self-auto">
              <Button
                v-if="showFollowAction"
                variant="secondary"
                size="sm"
                class="w-full rounded-full sm:w-auto"
                :disabled="relationshipBusy"
                @click="openDirectMessage"
              >
                <MessageCircle class="h-4 w-4" />
                {{ t('account.actions.directMessage') }}
              </Button>
              <Button
                v-if="showFollowAction && !isFollowing"
                variant="default"
                size="sm"
                class="w-full rounded-full sm:w-auto"
                :disabled="relationshipBusy"
                @click="followUser"
              >
                {{ t('account.header.follow') }}
              </Button>
              <Button
                v-else-if="showFollowAction"
                variant="outline"
                size="sm"
                class="w-full rounded-full sm:w-auto"
                :disabled="relationshipBusy"
                @click="followUser"
              >
                {{ t('account.header.unfollow') }}
              </Button>
              <DropdownMenu>
                <DropdownMenuTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-8 w-8 shrink-0 rounded-full text-muted-foreground hover:bg-accent"
                  >
                    <MoreHorizontal class="h-4 w-4" />
                    <span class="sr-only">
                      {{ t('account.header.moreActions') }}
                    </span>
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" class="w-52">
                  <DropdownMenuItem @click="openPublicProfile">
                    <ExternalLink class="h-4 w-4" />
                    {{ t('account.actions.openPublicProfile') }}
                  </DropdownMenuItem>
                  <DropdownMenuItem @click="copyProfileLink">
                    <Copy class="h-4 w-4" />
                    {{ t('account.actions.copyProfileLink') }}
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    v-if="showFollowAction"
                    :disabled="relationshipBusy"
                    @click="openDirectMessage"
                  >
                    <MessageCircle class="h-4 w-4" />
                    {{ t('account.actions.directMessage') }}
                  </DropdownMenuItem>
                  <template v-if="visibilityActions">
                    <DropdownMenuSeparator />
                    <DropdownMenuItem :disabled="relationshipBusy" @select="emit('visibility', 'muteDay')">
                      {{ t('visibility.muteDay') }}
                    </DropdownMenuItem>
                    <DropdownMenuItem :disabled="relationshipBusy" @select="emit('visibility', 'mute')">
                      {{ t('visibility.mute') }}
                    </DropdownMenuItem>
                    <DropdownMenuItem v-if="!blockedByViewer" :disabled="relationshipBusy" @select="emit('visibility', 'block')">
                      {{ t('visibility.block') }}
                    </DropdownMenuItem>
                  </template>
                  <DropdownMenuItem @click="refreshProfile">
                    <RefreshCw class="h-4 w-4" />
                    {{ t('account.actions.refreshProfile') }}
                  </DropdownMenuItem>
                  <DropdownMenuSeparator v-if="isSelfProfile" />
                  <DropdownMenuItem
                    v-if="isSelfProfile"
                    @click="goToAccountSettings"
                  >
                    <Settings class="h-4 w-4" />
                    {{ t('account.actions.accountSettings') }}
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    v-if="isSelfProfile"
                    @click="goToAccountSecurity"
                  >
                    <Shield class="h-4 w-4" />
                    {{ t('account.actions.securitySettings') }}
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          </div>

          <div class="border-t border-[var(--divider)]" />

          <div class="flex flex-col items-stretch gap-4 sm:flex-row sm:items-center">
            <div class="grid flex-1 grid-cols-3 gap-2">
              <button
                type="button"
                class="bento-tile flex flex-col items-center gap-0.5 px-2 py-2.5 text-center transition-colors hover:bg-accent hover:text-accent-foreground"
                @click="openStatsDialog('followers')"
              >
                <span class="tabular-nums text-lg font-semibold leading-tight">
                  {{ formatNumber(user.stats.followersCount) }}
                </span>
                <span class="text-xs text-muted-foreground">
                  {{ t('account.header.followers') }}
                </span>
              </button>
              <button
                type="button"
                class="bento-tile flex flex-col items-center gap-0.5 px-2 py-2.5 text-center transition-colors hover:bg-accent hover:text-accent-foreground"
                @click="openStatsDialog('following')"
              >
                <span class="tabular-nums text-lg font-semibold leading-tight">
                  {{ formatNumber(user.stats.followingCount) }}
                </span>
                <span class="text-xs text-muted-foreground">
                  {{ t('account.header.following') }}
                </span>
              </button>
              <button
                v-if="analyticsAvailable"
                type="button"
                class="bento-tile flex flex-col items-center gap-0.5 px-2 py-2.5 text-center transition-colors hover:bg-accent hover:text-accent-foreground"
                @click="openStatsDialog('likes')"
              >
                <span class="tabular-nums text-lg font-semibold leading-tight">
                  {{ formatNumber(user.stats.likesCount) }}
                </span>
                <span class="text-xs text-muted-foreground">
                  {{ t('account.header.likes') }}
                </span>
              </button>
            </div>
            <div class="w-full space-y-1.5 sm:w-1/3">
              <div class="flex items-center justify-between">
                <Label
                  for="completion"
                  class="text-xs font-medium text-muted-foreground"
                >
                  {{ t('account.header.activeScore') }}
                </Label>
                <span class="tabular-nums text-xs font-semibold">
                  {{ formatNumber(user.point) }}
                </span>
              </div>
              <Progress
                :model-value="normalizedScore"
                class="h-1.5 w-full"
              />
            </div>
          </div>
      </div>
    </div>
  </section>
  <Tabs
    v-if="!socialMode && accountTabs.length > 0"
    :model-value="tabValue"
    class="mt-3 w-full min-w-0 max-w-full overflow-x-auto overscroll-x-contain py-1"
    @update:model-value="handleTabChange"
  >
    <TabsList class="inline-flex h-auto min-w-full justify-start gap-1 rounded-full bg-secondary p-1 [--tab-inset:4px] [--tab-fill:var(--primary)] sm:min-w-0">
      <TabsTrigger
        v-for="tab in accountTabs"
        :key="tab.to"
        :value="tab.name"
        class="flex-none rounded-full border-0 px-3.5 py-1.5 text-[13.5px] font-medium text-muted-foreground transition-colors hover:text-foreground data-[state=active]:font-semibold data-[state=active]:text-primary-foreground dark:data-[state=active]:border-transparent dark:data-[state=active]:text-primary-foreground"
      >
        {{ tab.name }}
      </TabsTrigger>
    </TabsList>
  </Tabs>

  <Dialog
    :open="statsDialogOpen"
    @update:open="statsDialogOpen = $event"
  >
    <DialogContent
      class="flex max-h-[88vh] max-w-xl flex-col overflow-hidden p-0"
    >
      <DialogHeader
        class="border-b border-[var(--divider)] px-5 py-3.5"
      >
        <DialogTitle
          class="flex items-center gap-2 text-base font-semibold tracking-tight"
        >
          <span
            class="flex h-7 w-7 items-center justify-center rounded-xl bg-secondary text-foreground"
          >
            <Heart v-if="activeStatsType === 'likes'" class="h-4 w-4" />
            <Users v-else class="h-4 w-4" />
          </span>
          {{ statsDialogTitle }}
        </DialogTitle>
        <DialogDescription class="pl-9 text-xs text-muted-foreground">
          {{ statsDialogDescription }}
        </DialogDescription>
      </DialogHeader>

      <div
        v-if="activeStatsType === 'likes'"
        class="grid gap-3 px-5 py-4"
      >
        <div
          v-if="likesLoading"
          class="grid gap-3 sm:grid-cols-2"
        >
          <Skeleton
            v-for="item in 6"
            :key="item"
            class="h-20 rounded-xl"
          />
        </div>
        <div
          v-else-if="likesError"
          class="flex flex-col items-center justify-center gap-2 rounded-xl bg-secondary py-10 text-center"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 text-rose-500"
          >
            <AlertTriangle class="h-5 w-5" />
          </span>
          <p class="text-sm font-medium">
            {{ likesError }}
          </p>
          <Button
            variant="secondary"
            size="sm"
            class="h-8 rounded-full"
            @click="loadLikesAnalytics"
          >
            <RefreshCw class="h-3.5 w-3.5" />
            {{ t('common.refresh') }}
          </Button>
        </div>
        <div v-else class="grid gap-3 sm:grid-cols-2">
          <div
            v-for="item in likesStatItems"
            :key="item.label"
            class="bento-tile p-3.5"
          >
            <div
              class="flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-wider text-muted-foreground"
            >
              <Heart class="h-3 w-3" />
              {{ item.label }}
            </div>
            <div class="mt-2 tabular-nums text-2xl font-semibold tracking-tight">
              {{ item.value }}
            </div>
          </div>
        </div>
      </div>

      <div v-else class="flex min-h-0 flex-col gap-3 px-5 py-4">
        <div
          class="bento-tile flex items-center justify-between px-3.5 py-2.5 text-xs"
        >
          <span class="text-muted-foreground">
            {{
              t('account.stats.total', {
                count: formatNumber(relationshipTotal)
              })
            }}
          </span>
          <span
            :class="[
              PILL_BASE,
              'border-0 bg-[var(--primary-soft)] text-primary'
            ]"
          >
            <Users class="h-3 w-3" />
            {{
              activeStatsType === 'followers'
                ? t('account.header.followers')
                : t('account.header.following')
            }}
          </span>
        </div>

        <ScrollArea
          class="min-h-[280px] flex-1 rounded-xl bg-secondary/60"
        >
          <div class="space-y-1 p-2">
            <template
              v-if="relationshipLoading && relationshipUsers.length === 0"
            >
              <div
                v-for="item in 6"
                :key="item"
                class="flex items-center gap-3 rounded-xl p-2"
              >
                <Skeleton class="h-10 w-10 rounded-full" />
                <div class="flex-1 space-y-2">
                  <Skeleton class="h-4 w-32" />
                  <Skeleton class="h-3 w-20" />
                </div>
              </div>
            </template>

            <div
              v-else-if="relationshipError"
              class="flex flex-col items-center justify-center gap-2 py-10 text-center"
            >
              <span
                class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 text-rose-500"
              >
                <AlertTriangle class="h-5 w-5" />
              </span>
              <p class="text-sm font-medium">
                {{ relationshipError }}
              </p>
              <Button
                variant="secondary"
                size="sm"
                class="h-8 rounded-full"
                @click="loadRelationshipUsers(true)"
              >
                <RefreshCw class="h-3.5 w-3.5" />
                {{ t('common.refresh') }}
              </Button>
            </div>

            <div
              v-else-if="relationshipUsers.length === 0"
              class="flex flex-col items-center justify-center gap-2 py-10 text-center"
            >
              <span
                class="flex h-12 w-12 items-center justify-center rounded-full bg-secondary text-muted-foreground"
              >
                <Inbox class="h-5 w-5" />
              </span>
              <p class="text-sm font-medium">
                {{
                  activeStatsType === 'followers'
                    ? t('account.stats.emptyFollowers')
                    : t('account.stats.emptyFollowing')
                }}
              </p>
            </div>

            <template v-else>
              <button
                v-for="item in relationshipUsers"
                :key="item.id"
                type="button"
                class="flex w-full items-center gap-3 rounded-xl p-2 text-left transition-colors hover:bg-accent"
                @click="openUserProfile(item.id)"
              >
                <Avatar class="h-10 w-10 shrink-0">
                  <AvatarImage :src="item.avatarUrl" />
                  <AvatarFallback class="bg-secondary text-xs font-semibold text-foreground">
                    {{ getUserInitials(item) }}
                  </AvatarFallback>
                </Avatar>
                <div class="min-w-0 flex-1">
                  <div class="truncate text-sm font-medium">
                    {{ item.name || item.username }}
                  </div>
                  <div class="truncate text-xs text-muted-foreground">
                    @{{ item.username }}
                  </div>
                </div>
                <span
                  v-if="item.relationship.isFollowing"
                  :class="[
                    PILL_BASE,
                    'border-0 bg-[var(--primary-soft)] text-primary'
                  ]"
                >
                  {{ t('account.stats.followingBadge') }}
                </span>
                <UserRound
                  v-else
                  class="h-4 w-4 shrink-0 text-muted-foreground"
                />
              </button>
            </template>
          </div>
        </ScrollArea>

        <div
          v-if="relationshipHasNext"
          class="flex justify-center"
        >
          <Button
            variant="secondary"
            size="sm"
            class="h-8 rounded-full"
            :disabled="relationshipLoading"
            @click="loadRelationshipUsers(false)"
          >
            <Loader2
              v-if="relationshipLoading"
              class="h-3.5 w-3.5 animate-spin"
            />
            {{
              relationshipLoading
                ? t('common.loading')
                : t('common.loadMore')
            }}
          </Button>
        </div>
      </div>
    </DialogContent>
  </Dialog>
</template>

