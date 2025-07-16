<!-- 文件路径: pages/account.vue -->
<script setup lang="ts">
import { ref } from 'vue';
import { Button } from '@/components/ui/button';
import { apiFetch } from '@/composables/useApi';
import { toast } from 'vue-sonner';
import { Progress } from '@/components/ui/progress';
import { useI18n } from 'vue-i18n';

const preferenceStore = usePreferenceStore();

// 1. 获取 i18n 的工具函数
const { t } = useI18n();

const localePath = useLocalePath();

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
  point: 50
});

const baseAccountTabs = [
  {
    name: t('account.tabs.overview'),
    to: 'account-overview'
  },
  {
    name: t('account.tabs.settings'),
    to: 'account-settings'
  },
  {
    name: t('account.tabs.profile'),
    to: 'account-profile'
  },
  {
    name: t('account.tabs.appearance'),
    to: 'account-appearance'
  },
  {
    name: t('account.tabs.security'),
    to: 'account-security'
  },
  { name: t('account.tabs.active'), to: 'account-active' },
  {
    name: t('account.tabs.statements'),
    to: 'account-statements'
  }
];

// 3. ✨ 创建一个 computed 属性来生成最终给模板使用的数据
const localizedAccountTabs = computed(() => {
  return baseAccountTabs.map(tab => ({
    // ✨ 使用 t() 函数来翻译名称
    name: t(tab.name),
    // ✨ 使用 localePath() 函数来本地化链接
    to: localePath(tab.to)
  }));
});

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

  try {
    const response = (await apiFetch(
      `/api/v1/analytics/users/${preferenceStore.preferences.user.userId}/stats`,
      {
        method: 'GET'
      }
    )) as { data?: { user?: any } };

    user.value.point =
      response.data?.user.engagementScore || 0;
  } catch (error) {
    console.error('Error fetching user analytics:', error);
    toast.error('Failed to fetch user analytics.');
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
      :account-tabs="localizedAccountTabs"
      v-model="activeTab"
    />

    <!-- 4. 子页面渲染出口 -->
    <div class="content-below-tabs">
      <NuxtPage />
    </div>
  </div>
</template>
