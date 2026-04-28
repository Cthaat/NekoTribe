<!-- 文件路径: pages/account.vue -->
<script setup lang="ts">
import { ref } from 'vue';
import { Button } from '@/components/ui/button';
import {
  v2GetMe,
  v2GetUserAnalytics
} from '@/services';
import { toast } from 'vue-sonner';
import { useI18n } from 'vue-i18n';

// 1. 获取 i18n 的工具函数
const { t } = useI18n();

const localePath = useLocalePath();

interface AccountHeaderUser {
  name: string;
  title: string;
  location: string;
  email: string;
  avatar: string;
  stats: {
    followersCount: number;
    followingCount: number;
    likesCount: number;
  };
  point: number;
}

const user = ref<AccountHeaderUser>({
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
    const me = await v2GetMe();
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
      :account-tabs="localizedAccountTabs"
      v-model="activeTab"
    />

    <!-- 4. 子页面渲染出口 -->
    <div class="content-below-tabs">
      <NuxtPage />
    </div>
  </div>
</template>

