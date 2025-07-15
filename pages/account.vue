<!-- 文件路径: pages/account.vue -->
<script setup lang="ts">
import { ref } from 'vue';
import { Button } from '@/components/ui/button';
import { apiFetch } from '@/composables/useApi';
import { toast } from 'vue-sonner';
import { Progress } from '@/components/ui/progress';

const preferenceStore = usePreferenceStore();

// 假设这是从 API 获取的用户数据
const user = ref({
  name: '',
  title: '',
  location: '',
  email: '',
  avatar: '',
  stats: {
    followersCount: 0,
    followingCount: 0,
    likesCount: 0
  },
  profileCompletion: 50
});

// 为页面内的横向选项卡导航定义数据
const accountTabs = [
  { name: 'Overview', to: '/account/overview' },
  { name: 'Settings', to: '/account/settings' },
  { name: 'Profile', to: '/account/profile' },
  { name: 'Appearance', to: '/account/appearance' },
  { name: 'Security', to: '/account/security' },
  { name: 'Active', to: '/account/active' },
  { name: 'Statements', to: '/account/statements' }
];

const activeTab = ref('Overview');

onMounted(async () => {
  try {
    const response = (await apiFetch('/api/v1/users/me', {
      method: 'GET'
    })) as { data?: { userData?: { userInfo?: any } } };

    user.value.name =
      response.data?.userData?.userInfo?.username || '';
    user.value.title =
      response.data?.userData?.userInfo?.displayName || '';
    user.value.location =
      response.data?.userData?.userInfo?.location || '';
    user.value.email =
      response.data?.userData?.userInfo?.email || '';
    user.value.avatar =
      response.data?.userData?.userInfo?.avatarUrl || '';

    console.log('Fetched user info:', user);
  } catch (error) {
    console.error('Error fetching user info:', error);
    toast.error('Failed to fetch user info.');
  }

  try {
    const response = (await apiFetch(
      `/api/v1/users/${preferenceStore.preferences.user.userId}/stats`,
      {
        method: 'GET'
      }
    )) as { data?: { userData?: { userInfo?: any } } };

    user.value.stats.followersCount =
      response.data?.userData?.userInfo?.followersCount ||
      0;
    user.value.stats.followingCount =
      response.data?.userData?.userInfo?.followingCount ||
      0;
    user.value.stats.likesCount =
      response.data?.userData?.userInfo?.likesCount || 0;

    console.log('Fetched user info analytics:', user);
  } catch (error) {
    console.error('Error fetching user info:', error);
    toast.error('Failed to fetch user info.');
  }
});
</script>

<template>
  <div class="p-4 sm:p-6 lg:p-8 space-y-8">
    <!-- 1. 顶部的 Header: 标题和操作按钮 -->
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">
          Account - {{ activeTab }}
        </h1>
        <p class="text-muted-foreground text-sm">
          Home - Account
        </p>
      </div>
      <div class="flex items-center space-x-2">
        <Button variant="outline">Filter</Button>
        <Button>Create</Button>
      </div>
    </div>

    <AccountHeaderCard
      :user="user"
      :account-tabs="accountTabs"
      v-model="activeTab"
    />

    <!-- 4. 子页面渲染出口 -->
    <div class="content-below-tabs">
      <NuxtPage />
    </div>
  </div>
</template>
