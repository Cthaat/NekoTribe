<!-- 文件路径: pages/account.vue -->
<script setup lang="ts">
import { ref } from 'vue';
import { Button } from '@/components/ui/button';
import {
  v2GetMe,
  v2GetUserAnalytics
} from '@/services';
import { toast } from 'vue-sonner';

const { t } = useAppLocale();

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
  point: 50
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

onMounted(async () => {
  try {
    const me = await v2GetMe();
    user.value.id = me.id;
    user.value.name = me.username;
    user.value.title = me.name;
    user.value.location = me.location;
    user.value.email = me.email;
    user.value.avatar = me.avatarUrl;
    user.value.stats.followersCount = me.followersCount;
    user.value.stats.followingCount = me.followingCount;
    user.value.stats.likesCount = me.likesCount;
    const analytics = await v2GetUserAnalytics(me.id);
    user.value.point = analytics.engagementScore;
  } catch (error) {
    console.error(t('account.errors.loadUser'), error);
    toast.error(t('account.errors.loadUser'));
  }
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
        <Button variant="outline">{{ t('common.filter') }}</Button>
        <Button>{{ t('common.create') }}</Button>
      </div>
    </div>

    <AccountHeaderCard
      :user="user"
      :account-tabs="localizedAccountTabs"
      v-model="activeTab"
    />

    <!-- 4. 子页面渲染出口 -->
    <div class="content-below-tabs">
      <NuxtPage />
    </div>
  </div>
</template>

