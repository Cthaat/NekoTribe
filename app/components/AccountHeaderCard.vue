<script setup lang="ts">
import {
  computed,
  ref,
  watch
} from 'vue';
import AvatarUploader from '@/components/AvatarUploader.vue'; // 导入你的新组件
// 1. 导入所有这个组件需要的依赖项
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
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
import {
  Alert,
  AlertDescription
} from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
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
  Copy,
  ExternalLink,
  Heart,
  Mail,
  MapPin,
  MoreHorizontal,
  RefreshCw,
  Settings,
  Shield,
  User,
  UserRound
} from 'lucide-vue-next';
import type { PropType } from 'vue';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '~/stores/user'; // 导入 store
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

// 2. 为 props 定义清晰的 TypeScript 类型
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

// 3. 使用 defineProps 接收从父组件传递过来的数据
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

// 3.定义 emits，声明该组件会触发 'update:user' 事件
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

// 4. 处理头像更新的正确方式
const handleAvatarUpdate = (
  newAvatarRelativePath: string
) => {
  // 创建一个 props.user 的副本
  const updatedUser = { ...props.user };
  // 更新副本的 avatar 属性 (假设后端返回的是相对路径)
  // 你需要在这里拼接完整的 URL，或者确保你的 API 调用者来做这件事
  const BACKEND_URL = ''; // 示例 URL
  updatedUser.avatar = `${BACKEND_URL}${newAvatarRelativePath}`;
  // c. 通过 emit 事件将整个更新后的 user 对象发送给父组件
  emit('update:user', updatedUser);
};

// 将需要传递给 AvatarUploader 的数据包装成一个 computed 属性
//    这样可以确保当 props.user 变化时，子组件也能接收到更新
const avatarUploaderProps = computed(() => ({
  name: props.user.name,
  avatar: props.user.avatar
}));

const MAX_POSSIBLE_SCORE = 3000;

const normalizedScore = computed(() => {
  const originalScore = props.user.point;
  const minScore = 0; // 最小可能分数

  // 应用归一化公式
  let score_0_to_100 =
    ((originalScore - minScore) /
      (MAX_POSSIBLE_SCORE - minScore)) *
    100;

  // 3. 确保分数不会超过 100 或低于 0（处理边界情况）
  //    如果原始分数可能超过你设定的最大值，这一步很重要
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
  } catch (error) {
    console.error(t('common.operationFailed'), error);
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
  } catch (error) {
    console.error(t('account.stats.loadFailed'), error);
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
  } catch (error) {
    console.error(t('account.stats.loadFailed'), error);
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
  <!-- 整个组件的最外层是一个 Card -->
  <Card>
    <!-- a. 卡片内容区，只包含需要内边距 (p-6) 的用户信息 -->
    <CardContent class="p-6">
      <div
        class="flex flex-col sm:flex-row items-start gap-6"
      >
        <AvatarUploader
          :user="avatarUploaderProps"
          class="absolute bottom-0 right-0"
          @update:avatar="handleAvatarUpdate"
        />

        <!-- 右侧的所有信息，使用 space-y-4 来创建垂直间距 -->
        <div class="flex-1 space-y-4">
          <!-- 用户名和操作按钮 -->
          <div class="flex items-center justify-between">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="text-xl font-semibold">
                  {{ user.name }}
                </h2>
                <Badge
                  variant="secondary"
                  class="gap-1.5 rounded-full px-2 py-0.5 text-xs"
                >
                  <span
                    class="h-2 w-2 rounded-full"
                    :class="onlineStatusClass(user.onlineStatus)"
                  />
                  {{ onlineStatusLabel(user.onlineStatus) }}
                </Badge>
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
                class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-muted-foreground mt-1"
              >
                <span
                  v-if="user.title"
                  class="flex items-center gap-1.5"
                  ><User class="w-4 h-4" />{{
                    user.title
                  }}</span
                >
                <span class="flex items-center gap-1.5"
                  ><MapPin class="w-4 h-4" />{{
                    user.location
                  }}</span
                >
                <span
                  v-if="user.email"
                  class="flex items-center gap-1.5"
                  ><Mail class="w-4 h-4" />{{
                    user.email
                  }}</span
                >
              </div>
            </div>
            <div class="flex items-center space-x-2">
              <Button
                v-if="showFollowAction && !isFollowing"
                variant="outline"
                @click="followUser"
              >
                {{ t('account.header.follow') }}
              </Button>
              <Button
                v-else-if="showFollowAction"
                variant="destructive"
                @click="followUser"
              >
                {{ t('account.header.unfollow') }}
              </Button>
              <DropdownMenu>
                <DropdownMenuTrigger as-child>
                  <Button variant="ghost" size="icon">
                    <MoreHorizontal class="w-4 h-4" />
                    <span class="sr-only">{{
                      t('account.header.moreActions')
                    }}</span>
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

          <!-- 分割线 -->
          <div class="border-t" />

          <!-- 统计数据和进度条 -->
          <div
            class="flex flex-col sm:flex-row items-center gap-4"
          >
            <div class="flex-1 grid grid-cols-3 gap-4">
              <Button
                type="button"
                variant="ghost"
                class="h-auto flex-col gap-0 rounded-lg px-3 py-2 text-center"
                @click="openStatsDialog('followers')"
              >
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  {{ formatNumber(user.stats.followersCount) }}
                </p>
                <p class="text-xs text-muted-foreground">
                  {{ t('account.header.followers') }}
                </p>
              </Button>
              <Button
                type="button"
                variant="ghost"
                class="h-auto flex-col gap-0 rounded-lg px-3 py-2 text-center"
                @click="openStatsDialog('following')"
              >
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  {{ formatNumber(user.stats.followingCount) }}
                </p>
                <p class="text-xs text-muted-foreground">
                  {{ t('account.header.following') }}
                </p>
              </Button>
              <Button
                type="button"
                variant="ghost"
                class="h-auto flex-col gap-0 rounded-lg px-3 py-2 text-center"
                @click="openStatsDialog('likes')"
              >
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  {{ formatNumber(user.stats.likesCount) }}
                </p>
                <p class="text-xs text-muted-foreground">
                  {{ t('account.header.likes') }}
                </p>
              </Button>
            </div>
            <div class="w-full sm:w-1/3">
              <Label
                for="completion"
                class="text-sm font-medium"
              >
                {{ t('account.header.activeScore') }}
              </Label>
              <div class="flex items-center gap-2">
                <Progress
                  :model-value="normalizedScore"
                  class="w-full"
                />
                <span class="font-semibold text-sm">{{
                  user.point
                }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </CardContent>
  </Card>
  <!-- b. 账户子页面导航 -->
  <Tabs
    v-if="accountTabs.length > 0"
    :model-value="tabValue"
    class="w-full overflow-x-auto"
    @update:model-value="handleTabChange"
  >
    <TabsList
      class="inline-flex h-auto min-w-full justify-start sm:min-w-0"
    >
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
    <DialogContent class="sm:max-w-xl">
      <DialogHeader>
        <DialogTitle>{{ statsDialogTitle }}</DialogTitle>
        <DialogDescription>
          {{ statsDialogDescription }}
        </DialogDescription>
      </DialogHeader>

      <div v-if="activeStatsType === 'likes'" class="space-y-4">
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
        <Alert
          v-else-if="likesError"
          variant="destructive"
        >
          <AlertDescription>{{ likesError }}</AlertDescription>
        </Alert>
        <div v-else class="grid gap-3 sm:grid-cols-2">
          <Card
            v-for="item in likesStatItems"
            :key="item.label"
            class="gap-0 py-0"
          >
            <CardContent class="p-4">
              <div
                class="flex items-center gap-2 text-sm text-muted-foreground"
              >
                <Heart class="h-4 w-4" />
                {{ item.label }}
              </div>
              <div class="mt-2 text-2xl font-semibold">
                {{ item.value }}
              </div>
            </CardContent>
          </Card>
        </div>
      </div>

      <div v-else class="space-y-4">
        <div
          class="flex items-center justify-between rounded-lg bg-muted/50 px-3 py-2 text-sm"
        >
          <span class="text-muted-foreground">
            {{
              t('account.stats.total', {
                count: formatNumber(relationshipTotal)
              })
            }}
          </span>
          <Badge variant="secondary">
            {{
              activeStatsType === 'followers'
                ? t('account.header.followers')
                : t('account.header.following')
            }}
          </Badge>
        </div>

        <ScrollArea class="h-[360px] rounded-lg border">
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
              class="p-6 text-center text-sm text-destructive"
            >
              {{ relationshipError }}
            </div>

            <div
              v-else-if="relationshipUsers.length === 0"
              class="p-8 text-center text-sm text-muted-foreground"
            >
              {{
                activeStatsType === 'followers'
                  ? t('account.stats.emptyFollowers')
                  : t('account.stats.emptyFollowing')
              }}
            </div>

            <template v-else>
              <Button
                v-for="item in relationshipUsers"
                :key="item.id"
                type="button"
                variant="ghost"
                class="h-auto w-full justify-start gap-3 rounded-lg p-2 text-left"
                @click="openUserProfile(item.id)"
              >
                <Avatar class="h-10 w-10">
                  <AvatarImage :src="item.avatarUrl" />
                  <AvatarFallback>
                    {{ getUserInitials(item) }}
                  </AvatarFallback>
                </Avatar>
                <div class="min-w-0 flex-1">
                  <div
                    class="truncate text-sm font-medium text-foreground"
                  >
                    {{ item.name || item.username }}
                  </div>
                  <div
                    class="truncate text-xs text-muted-foreground"
                  >
                    @{{ item.username }}
                  </div>
                </div>
                <Badge
                  v-if="item.relationship.isFollowing"
                  variant="secondary"
                >
                  {{ t('account.stats.followingBadge') }}
                </Badge>
                <UserRound
                  v-else
                  class="h-4 w-4 text-muted-foreground"
                />
              </Button>
            </template>
          </div>
        </ScrollArea>

        <div
          v-if="relationshipHasNext"
          class="flex justify-center"
        >
          <Button
            variant="outline"
            :disabled="relationshipLoading"
            @click="loadRelationshipUsers(false)"
          >
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

