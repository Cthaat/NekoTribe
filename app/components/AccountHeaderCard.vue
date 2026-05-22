<script setup lang="ts">
import {
  computed,
  ref,
  watch
} from 'vue';
import AvatarUploader from '@/components/AvatarUploader.vue';
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
  Copy,
  ExternalLink,
  Heart,
  Inbox,
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
  }
});

const emit = defineEmits<{
  (e: 'update:user', user: UserData): void;
  (
    e: 'follow',
    user: UserData,
    action: 'follow' | 'unfollow'
  ): void;
  (e: 'refresh'): void;
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
  const BACKEND_URL = '';
  updatedUser.avatar = `${BACKEND_URL}${newAvatarRelativePath}`;
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
    {
      label: t('account.stats.totalLikesGiven'),
      value: formatNumber(analytics?.totalLikesGiven ?? 0)
    },
    {
      label: t('account.stats.totalCommentsMade'),
      value: formatNumber(analytics?.totalCommentsMade ?? 0)
    },
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
    ? 'bg-emerald-500'
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
  if (props.user.id <= 0 || isSelfProfile.value) return;
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
  if (props.user.id <= 0 || likesLoading.value) return;

  likesLoading.value = true;
  likesError.value = null;

  try {
    likesAnalytics.value = await v2GetUserAnalytics(props.user.id);
  } catch {
    likesError.value = t('account.stats.loadFailed');
  } finally {
    likesLoading.value = false;
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

const isFollowing = ref(props.user.follow === 'follow');
const showFollowAction = computed(() => {
  return props.user.id > 0 && props.user.id !== currentUserId.value;
});

watch(
  () => props.user.follow,
  newValue => {
    isFollowing.value = newValue === 'follow';
  }
);

watch(
  () => [route.path, props.accountTabs] as const,
  syncActiveTabFromRoute,
  { immediate: true }
);

function followUser() {
  if (
    props.user.id ===
    preferenceStore.preferences.user.id
  ) {
    toast.error(t('account.header.selfFollowError'));
    return;
  }
  if (isFollowing.value) {
    isFollowing.value = false;
    emit('follow', props.user, 'unfollow');
  } else {
    isFollowing.value = true;
    emit('follow', props.user, 'follow');
  }
}
</script>

<template>
  <section
    class="overflow-hidden rounded-xl border border-border/60 bg-card p-4 shadow-none sm:p-6"
  >
    <div class="flex flex-col items-start gap-6 sm:flex-row">
      <AvatarUploader
        :user="avatarUploaderProps"
        class="shrink-0"
        @update:avatar="handleAvatarUpdate"
      />

      <div class="min-w-0 flex-1 space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0 space-y-1.5">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <h2 class="min-w-0 truncate text-xl font-semibold tracking-tight">
                  {{ user.name }}
                </h2>
                <span
                  class="inline-flex items-center gap-1.5 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-xs font-medium text-muted-foreground"
                >
                  <span
                    class="h-1.5 w-1.5 rounded-full"
                    :class="onlineStatusClass(user.onlineStatus)"
                  />
                  {{ onlineStatusLabel(user.onlineStatus) }}
                </span>
                <span
                  v-if="user.onlineStatus !== 'online' && user.lastSeenAt"
                  class="text-xs text-muted-foreground"
                >
                  {{
                    t('account.header.lastSeen', {
                      time: formatLastSeen(user.lastSeenAt)
                    })
                  }}
                </span>
              </div>
              <div
                class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-muted-foreground"
              >
                <span
                  v-if="user.title"
                  class="flex items-center gap-1.5"
                >
                  <User class="h-3.5 w-3.5" />
                  {{ user.title }}
                </span>
                <span
                  v-if="user.location"
                  class="flex items-center gap-1.5"
                >
                  <MapPin class="h-3.5 w-3.5" />
                  {{ user.location }}
                </span>
                <span
                  v-if="user.email"
                  class="flex items-center gap-1.5"
                >
                  <Mail class="h-3.5 w-3.5" />
                  {{ user.email }}
                </span>
              </div>
            </div>
            <div class="flex items-center gap-2 self-start sm:self-auto">
              <Button
                v-if="showFollowAction"
                variant="secondary"
                size="sm"
                @click="openDirectMessage"
              >
                <MessageCircle class="h-4 w-4" />
                {{ t('account.actions.directMessage') }}
              </Button>
              <Button
                v-if="showFollowAction && !isFollowing"
                variant="default"
                size="sm"
                @click="followUser"
              >
                {{ t('account.header.follow') }}
              </Button>
              <Button
                v-else-if="showFollowAction"
                variant="outline"
                size="sm"
                @click="followUser"
              >
                {{ t('account.header.unfollow') }}
              </Button>
              <DropdownMenu>
                <DropdownMenuTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-8 w-8 rounded-full text-muted-foreground hover:bg-accent"
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
                    @click="openDirectMessage"
                  >
                    <MessageCircle class="h-4 w-4" />
                    {{ t('account.actions.directMessage') }}
                  </DropdownMenuItem>
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

          <div class="border-t border-border/60" />

          <div class="flex flex-col items-stretch gap-4 sm:flex-row sm:items-center">
            <div class="grid flex-1 grid-cols-3 gap-1 sm:gap-2">
              <button
                type="button"
                class="flex flex-col items-center gap-0.5 rounded-lg px-2 py-2 text-center transition-colors hover:bg-accent hover:text-accent-foreground"
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
                class="flex flex-col items-center gap-0.5 rounded-lg px-2 py-2 text-center transition-colors hover:bg-accent hover:text-accent-foreground"
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
                type="button"
                class="flex flex-col items-center gap-0.5 rounded-lg px-2 py-2 text-center transition-colors hover:bg-accent hover:text-accent-foreground"
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
    v-if="accountTabs.length > 0"
    :model-value="tabValue"
    class="w-full overflow-x-auto"
    @update:model-value="handleTabChange"
  >
    <TabsList class="inline-flex h-auto min-w-full justify-start sm:min-w-0">
      <TabsTrigger
        v-for="tab in accountTabs"
        :key="tab.to"
        :value="tab.name"
        class="flex-none px-3"
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
      class="flex max-h-[88vh] max-w-xl flex-col overflow-hidden rounded-xl border-border/60 p-0"
    >
      <DialogHeader
        class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
      >
        <DialogTitle
          class="flex items-center gap-2 text-base font-semibold tracking-tight"
        >
          <span
            v-if="activeStatsType === 'likes'"
            class="flex h-7 w-7 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 dark:text-rose-400"
          >
            <Heart class="h-4 w-4" />
          </span>
          <span
            v-else
            class="flex h-7 w-7 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
          >
            <Users class="h-4 w-4" />
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
            class="h-20 rounded-lg"
          />
        </div>
        <div
          v-else-if="likesError"
          class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-rose-200/70 bg-rose-50/40 py-10 text-center dark:border-rose-500/30 dark:bg-rose-500/10"
        >
          <span
            class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 text-rose-600 ring-1 ring-rose-500/30 dark:text-rose-400"
          >
            <AlertTriangle class="h-5 w-5" />
          </span>
          <p class="text-sm font-medium">
            {{ likesError }}
          </p>
          <Button
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
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
            class="rounded-lg border border-border/60 bg-muted/20 p-3"
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
          class="flex items-center justify-between rounded-lg border border-border/60 bg-muted/20 px-3 py-2 text-xs"
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
              'border-sky-200/70 bg-sky-500/10 text-sky-700 dark:border-sky-500/30 dark:text-sky-300'
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
          class="min-h-[280px] flex-1 rounded-lg border border-border/60"
        >
          <div class="space-y-1 p-2">
            <template
              v-if="relationshipLoading && relationshipUsers.length === 0"
            >
              <div
                v-for="item in 6"
                :key="item"
                class="flex items-center gap-3 rounded-lg p-2"
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
                class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 text-rose-600 ring-1 ring-rose-500/30 dark:text-rose-400"
              >
                <AlertTriangle class="h-5 w-5" />
              </span>
              <p class="text-sm font-medium">
                {{ relationshipError }}
              </p>
              <Button
                variant="outline"
                size="sm"
                class="h-8 rounded-md shadow-xs"
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
                class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 text-muted-foreground ring-1 ring-border/60"
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
                class="flex w-full items-center gap-3 rounded-lg p-2 text-left transition-colors hover:bg-muted/40"
                @click="openUserProfile(item.id)"
              >
                <Avatar class="h-10 w-10 shrink-0 ring-1 ring-border/60">
                  <AvatarImage :src="item.avatarUrl" />
                  <AvatarFallback class="bg-primary/10 text-xs font-semibold text-primary">
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
                    'border-emerald-200/70 bg-emerald-500/10 text-emerald-700 dark:border-emerald-500/30 dark:text-emerald-300'
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
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
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

