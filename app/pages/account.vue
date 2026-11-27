<script setup lang="ts">
import { useNuxtApp } from '#app';
import { onMounted, onUnmounted, ref } from 'vue';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import {
  v2GetMe,
  v2GetUserAnalytics
} from '@/services';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import { ChevronDown, Settings } from 'lucide-vue-next';

const { t } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const preferences = usePreferenceStore();

const localePath = useLocalePath();

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

const emptyAccount = (): AccountHeaderUser => ({
  id: 0,
  name: '',
  title: '',
  location: '',
  email: '',
  avatar: '',
  follow: 'follow',
  stats: {
    followersCount: 0,
    followingCount: 0,
    likesCount: 0
  },
  point: 50,
  onlineStatus: 'hidden',
  lastSeenAt: null
});
const user = ref(emptyAccount());
const loadFailed = ref(false);
let request = 0;
let unsubscribe: (() => void) | undefined;

const baseAccountTabs = [
  {
    labelKey: 'account.tabs.overview',
    to: 'account-overview'
  },
  {
    labelKey: 'account.tabs.profile',
    to: 'account-profile'
  },
  {
    labelKey: 'account.tabs.posts',
    to: 'account-posts'
  },
  {
    labelKey: 'account.tabs.likes',
    to: 'account-likes'
  },
  {
    labelKey: 'account.tabs.bookmarks',
    to: 'account-bookmarks'
  },
  {
    labelKey: 'account.tabs.appearance',
    to: 'account-appearance'
  }
];

const moreAccountTabs = [
  { labelKey: 'account.tabs.settings', to: 'account-settings' },
  { labelKey: 'account.tabs.security', to: 'account-security' },
  { labelKey: 'account.tabs.active', to: 'account-active' },
  { labelKey: 'account.tabs.billing', to: 'account-billing' },
  { labelKey: 'account.tabs.pro', to: 'account-pro' },
  { labelKey: 'account.tabs.statements', to: 'account-statements' },
  { labelKey: 'account.analytics.title', to: 'account-analytics' },
  { labelKey: 'aiUserProvider.title', to: 'account-ai-provider' }
];

const localizedAccountTabs = computed(() => {
  return baseAccountTabs.map(tab => ({
    name: t(tab.labelKey),
    to: localePath(tab.to)
  }));
});

const localizedMoreAccountTabs = computed(() => {
  return moreAccountTabs.map(tab => ({
    name: t(tab.labelKey),
    to: localePath(tab.to)
  }));
});

const activeTab = ref(t('account.tabs.overview'));
const route = useRoute();
const normalizedPath = computed(() => route.path.replace(/\/$/, ''));
const activeMoreTab = computed(() =>
  localizedMoreAccountTabs.value.find(tab => tab.to === normalizedPath.value) ??
  (normalizedPath.value.endsWith('/account/ai-provider')
    ? localizedMoreAccountTabs.value.find(tab => tab.to === localePath('account-ai-provider'))
    : undefined)
);
const isMoreTabActive = computed(() => activeMoreTab.value !== undefined);

function updateActiveTabFromRoute(): void {
  const active =
    localizedAccountTabs.value.find(tab => tab.to === normalizedPath.value) ??
    activeMoreTab.value;
  activeTab.value = active?.name ?? t('account.tabs.overview');
}

async function loadAccount(): Promise<void> {
  if (auth.isIdentityChanging || !preferences.isLoggedIn) return;
  const currentRequest = ++request;
  const revision = auth.revision;
  const isCurrent = () =>
    request === currentRequest && auth.revision === revision && !auth.isIdentityChanging;
  loadFailed.value = false;
  let me: Awaited<ReturnType<typeof v2GetMe>>;
  try {
    me = await app.runWithContext(v2GetMe);
  } catch {
    if (isCurrent()) loadFailed.value = true;
    return;
  }
  if (!isCurrent()) return;
  user.value = {
    ...emptyAccount(),
    id: me.id,
    name: me.username,
    title: me.name,
    location: me.location,
    email: me.email,
    avatar: me.avatarUrl,
    onlineStatus: me.onlineStatus,
    lastSeenAt: me.lastSeenAt,
    stats: {
      followersCount: me.followersCount,
      followingCount: me.followingCount,
      likesCount: me.likesCount
    }
  };
  try {
    const analytics = await app.runWithContext(() => v2GetUserAnalytics(me.id));
    if (isCurrent()) user.value.point = analytics.engagementScore;
  } catch {
    // Analytics is optional for the account header.
  }
}

function goToAccountTab(path: string, name: string): void {
  activeTab.value = name;
  void navigateTo(path);
}

onMounted(() => {
  let revision = auth.revision;
  let changing = auth.isIdentityChanging;
  unsubscribe = auth.subscribe(() => {
    if (revision === auth.revision && changing === auth.isIdentityChanging) return;
    revision = auth.revision;
    changing = auth.isIdentityChanging;
    request++;
    user.value = emptyAccount();
    loadFailed.value = false;
    if (!changing) {
      const settledRequest = request;
      queueMicrotask(() => {
        if (request === settledRequest) void loadAccount();
      });
    }
  });
  void loadAccount();
});

onUnmounted(() => {
  request++;
  unsubscribe?.();
});

watch(
  () => [normalizedPath.value, localizedAccountTabs.value, activeMoreTab.value] as const,
  updateActiveTabFromRoute,
  { immediate: true }
);
</script>

<template>
  <div class="grid w-full min-w-0 max-w-full gap-6 overflow-x-clip p-3 sm:p-6 lg:p-8">
    <div
      class="flex min-w-0 items-center justify-between gap-3"
    >
      <h1 class="min-w-0 truncate text-xl font-semibold tracking-tight sm:text-2xl">
        {{ t('account.title') }}
        <span class="text-muted-foreground">·</span>
        {{ activeTab }}
      </h1>
      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <Button
            variant="secondary"
            size="sm"
            class="pressable h-8 shrink-0 gap-1.5 rounded-full border-0 px-3 text-xs shadow-none"
            :class="isMoreTabActive
              ? 'bg-primary/15 font-semibold text-primary ring-1 ring-inset ring-primary/30 hover:bg-primary/20'
              : 'bg-secondary text-foreground hover:bg-accent'"
          >
            <Settings class="size-3.5" aria-hidden="true" />
            <span>{{ isMoreTabActive ? activeTab : t('account.tabs.settings') }}</span>
            <ChevronDown class="size-3 opacity-70" aria-hidden="true" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="end"
          class="w-48 rounded-[20px] p-1.5"
        >
          <DropdownMenuItem
            v-for="tab in localizedMoreAccountTabs"
            :key="tab.to"
            class="rounded-xl text-[13px] aria-[current=page]:bg-primary/10 aria-[current=page]:font-semibold aria-[current=page]:text-primary"
            :aria-current="tab === activeMoreTab ? 'page' : undefined"
            @select="goToAccountTab(tab.to, tab.name)"
          >
            {{ tab.name }}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>

    <div class="min-w-0">
      <div v-if="loadFailed" class="bento-card mb-3 flex flex-wrap items-center justify-between gap-2 px-4 py-3">
        <p role="alert" class="text-sm text-muted-foreground">{{ t('account.errors.loadUser') }}</p>
        <Button variant="secondary" size="sm" class="rounded-full" @click="loadAccount">{{ t('common.retry') }}</Button>
      </div>
      <AccountHeaderCard
        :key="user.id"
        :user="user"
        :account-tabs="localizedAccountTabs"
        v-model="activeTab"
        @refresh="loadAccount"
      />
    </div>

    <div class="content-below-tabs min-w-0">
      <NuxtPage />
    </div>
  </div>
</template>
