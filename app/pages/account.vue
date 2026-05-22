<script setup lang="ts">
import { ref } from 'vue';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
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
  createGroup,
  v2GetMe,
  v2GetUserAnalytics
} from '@/services';
import type { CreateGroupData } from '@/types/groups';
import {
  ChevronDown,
  Filter,
  FileText,
  ListFilter,
  Plus,
  Settings,
  Shield,
  UserRound,
  Users
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';

const { t } = useAppLocale();

const localePath = useLocalePath();
const filterDialogOpen = ref(false);
const createGroupOpen = ref(false);

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

const user = ref<AccountHeaderUser>({
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

const baseAccountTabs = [
  {
    labelKey: 'account.tabs.overview',
    to: 'account-overview'
  },
  {
    labelKey: 'account.tabs.settings',
    to: 'account-settings'
  },
  {
    labelKey: 'account.tabs.pro',
    to: 'account-pro'
  },
  {
    labelKey: 'account.tabs.billing',
    to: 'account-billing'
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
    labelKey: 'account.tabs.appearance',
    to: 'account-appearance'
  },
  {
    labelKey: 'account.tabs.security',
    to: 'account-security'
  },
  { labelKey: 'account.tabs.active', to: 'account-active' },
  {
    labelKey: 'account.tabs.statements',
    to: 'account-statements'
  }
];

const localizedAccountTabs = computed(() => {
  return baseAccountTabs.map(tab => ({
    name: t(tab.labelKey),
    to: localePath(tab.to)
  }));
});

const activeTab = ref(t('account.tabs.overview'));
const route = useRoute();

function updateActiveTabFromRoute(): void {
  const active = localizedAccountTabs.value.find(
    tab => tab.to === route.path
  );
  activeTab.value = active?.name ?? t('account.tabs.overview');
}

async function loadAccount(): Promise<void> {
  try {
    const me = await v2GetMe();
    user.value.id = me.id;
    user.value.name = me.username;
    user.value.title = me.name;
    user.value.location = me.location;
    user.value.email = me.email;
    user.value.avatar = me.avatarUrl;
    user.value.onlineStatus = me.onlineStatus;
    user.value.lastSeenAt = me.lastSeenAt;
    user.value.stats.followersCount = me.followersCount;
    user.value.stats.followingCount = me.followingCount;
    user.value.stats.likesCount = me.likesCount;
    const analytics = await v2GetUserAnalytics(me.id);
    user.value.point = analytics.engagementScore;
  } catch {
    toast.error(t('account.errors.loadUser'));
  }
}

function goToAccountTab(path: string, name: string): void {
  activeTab.value = name;
  filterDialogOpen.value = false;
  void navigateTo(path);
}

function createPost(): void {
  void navigateTo(localePath('/meow'));
}

function openCreateGroup(): void {
  createGroupOpen.value = true;
}

async function handleCreateGroup(
  data: CreateGroupData
): Promise<void> {
  try {
    await createGroup(data);
    toast.success(t('groups.feedback.created'));
    void navigateTo(localePath('/groups/my'));
  } catch (error) {
    toast.error(t('groups.feedback.createFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

onMounted(() => {
  updateActiveTabFromRoute();
  void loadAccount();
});

watch(
  () => [route.path, localizedAccountTabs.value] as const,
  updateActiveTabFromRoute
);
</script>

<template>
  <div class="grid w-full min-w-0 max-w-full gap-6 overflow-x-clip p-3 sm:p-6 lg:p-8">
    <div
      class="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
    >
      <div class="min-w-0 grid gap-1">
        <h1 class="text-xl font-semibold tracking-tight sm:text-2xl">
          {{ t('account.title') }}
          <span class="text-muted-foreground">·</span>
          {{ activeTab }}
        </h1>
        <p class="text-xs text-muted-foreground">
          {{ t('account.breadcrumb') }}
        </p>
      </div>
      <div
        class="flex w-full flex-col gap-2 sm:w-auto sm:flex-row sm:items-center"
      >
        <Button
          variant="outline"
          class="h-9 w-full rounded-md shadow-xs sm:w-auto"
          @click="filterDialogOpen = true"
        >
          <ListFilter class="h-3.5 w-3.5" />
          {{ t('common.filter') }}
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button class="h-9 w-full rounded-md shadow-xs sm:w-auto">
              <Plus class="h-3.5 w-3.5" />
              {{ t('common.create') }}
              <ChevronDown class="h-3.5 w-3.5 opacity-70" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent
            align="end"
            class="w-52 rounded-xl border-border/60 p-1"
          >
            <DropdownMenuItem
              class="gap-2 rounded-md"
              @click="createPost"
            >
              <FileText class="h-3.5 w-3.5 text-muted-foreground" />
              {{ t('account.actions.createPost') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              class="gap-2 rounded-md"
              @click="openCreateGroup"
            >
              <Users class="h-3.5 w-3.5 text-muted-foreground" />
              {{ t('account.actions.createGroup') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              class="gap-2 rounded-md"
              @click="
                goToAccountTab(
                  localePath('account-profile'),
                  t('account.tabs.profile')
                )
              "
            >
              <UserRound class="h-3.5 w-3.5 text-muted-foreground" />
              {{ t('account.actions.editProfile') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>

    <div class="min-w-0">
      <AccountHeaderCard
        :user="user"
        :account-tabs="localizedAccountTabs"
        v-model="activeTab"
        @refresh="loadAccount"
      />
    </div>

    <Dialog
      :open="filterDialogOpen"
      @update:open="filterDialogOpen = $event"
    >
      <DialogContent
        class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-lg"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
        >
          <DialogTitle
            class="flex items-center gap-2 text-base font-semibold tracking-tight"
          >
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-primary/10 text-primary"
            >
              <Filter class="h-4 w-4" />
            </span>
            {{ t('account.actions.filterTitle') }}
          </DialogTitle>
          <p class="pl-9 text-xs text-muted-foreground">
            {{ t('account.actions.filterDescription') }}
          </p>
        </DialogHeader>
        <div class="grid gap-2 px-5 py-4 sm:grid-cols-2">
          <button
            v-for="tab in localizedAccountTabs"
            :key="tab.to"
            type="button"
            class="flex items-center gap-3 rounded-lg border border-border/60 bg-card p-3 text-left transition-all hover:border-border hover:bg-muted/40 hover:shadow-sm"
            @click="goToAccountTab(tab.to, tab.name)"
          >
            <span
              class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted/60 text-muted-foreground"
            >
              <Settings
                v-if="tab.to.includes('/settings')"
                class="h-4 w-4"
              />
              <Shield
                v-else-if="tab.to.includes('/security')"
                class="h-4 w-4"
              />
              <UserRound v-else class="h-4 w-4" />
            </span>
            <span class="truncate text-sm font-medium">
              {{ tab.name }}
            </span>
          </button>
        </div>
      </DialogContent>
    </Dialog>

    <CreateGroupModal
      v-model:open="createGroupOpen"
      @create="handleCreateGroup"
    />

    <div class="content-below-tabs min-w-0">
      <NuxtPage />
    </div>
  </div>
</template>
