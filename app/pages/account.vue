<!-- 文件路径: pages/account.vue -->
<script setup lang="ts">
import { ref } from 'vue';
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
  createGroup,
  v2GetMe,
  v2GetUserAnalytics
} from '@/services';
import type { CreateGroupData } from '@/types/groups';
import {
  ChevronDown,
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
    labelKey: 'account.tabs.profile',
    to: 'account-profile'
  },
  {
    labelKey: 'account.tabs.posts',
    to: 'account-posts'
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
  } catch (error) {
    console.error(t('account.errors.loadUser'), error);
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
  void loadAccount();
});
</script>

<template>
  <div class="p-4 sm:p-6 lg:p-8 space-y-8">
    <!-- 1. 顶部的 Header: 标题和操作按钮 -->
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">
          {{ t('account.title') }} - {{ activeTab }}
        </h1>
        <p class="text-muted-foreground text-sm">
          {{ t('account.breadcrumb') }}
        </p>
      </div>
      <div class="flex items-center space-x-2">
        <Button
          variant="outline"
          class="gap-2"
          @click="filterDialogOpen = true"
        >
          <ListFilter class="h-4 w-4" />
          {{ t('common.filter') }}
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button class="gap-2">
              <Plus class="h-4 w-4" />
              {{ t('common.create') }}
              <ChevronDown class="h-4 w-4 opacity-70" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" class="w-48">
            <DropdownMenuItem @click="createPost">
              <FileText class="h-4 w-4" />
              {{ t('account.actions.createPost') }}
            </DropdownMenuItem>
            <DropdownMenuItem @click="openCreateGroup">
              <Users class="h-4 w-4" />
              {{ t('account.actions.createGroup') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              @click="goToAccountTab(localePath('account-profile'), t('account.tabs.profile'))"
            >
              <UserRound class="h-4 w-4" />
              {{ t('account.actions.editProfile') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>

    <AccountHeaderCard
      :user="user"
      :account-tabs="localizedAccountTabs"
      v-model="activeTab"
      @refresh="loadAccount"
    />

    <Dialog
      :open="filterDialogOpen"
      @update:open="filterDialogOpen = $event"
    >
      <DialogContent class="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {{ t('account.actions.filterTitle') }}
          </DialogTitle>
          <DialogDescription>
            {{ t('account.actions.filterDescription') }}
          </DialogDescription>
        </DialogHeader>
        <div class="grid gap-2 sm:grid-cols-2">
          <Button
            v-for="tab in localizedAccountTabs"
            :key="tab.to"
            type="button"
            variant="outline"
            class="h-auto justify-start gap-3 rounded-lg px-3 py-3 text-left"
            @click="goToAccountTab(tab.to, tab.name)"
          >
            <Settings
              v-if="tab.to.includes('/settings')"
              class="h-4 w-4 text-muted-foreground"
            />
            <Shield
              v-else-if="tab.to.includes('/security')"
              class="h-4 w-4 text-muted-foreground"
            />
            <UserRound
              v-else
              class="h-4 w-4 text-muted-foreground"
            />
            <span class="font-medium">{{ tab.name }}</span>
          </Button>
        </div>
      </DialogContent>
    </Dialog>

    <CreateGroupModal
      v-model:open="createGroupOpen"
      @create="handleCreateGroup"
    />

    <!-- 4. 子页面渲染出口 -->
    <div class="content-below-tabs">
      <NuxtPage />
    </div>
  </div>
</template>

