<!-- 文件路径: pages/account.vue -->
<script setup lang="ts">
import { ref } from 'vue';
import { Button } from '@/components/ui/button';
import {
  Card,
  CardContent,
  CardHeader
} from '@/components/ui/card';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Progress } from '@/components/ui/progress';
import {
  ArrowUp,
  ArrowDown,
  User,
  Mail,
  MapPin,
  MoreHorizontal
} from 'lucide-vue-next';

// 假设这是从 API 获取的用户数据
const user = ref({
  name: 'Max Smith',
  title: 'Developer',
  location: 'SF, Bay Area',
  email: 'max@kt.com',
  avatar: '/avatars/01.png', // 请确保在 public/avatars/ 目录下有这张图片
  stats: {
    earnings: 4500,
    projects: 80,
    successRate: 60
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
</script>

<template>
  <div class="p-4 sm:p-6 lg:p-8 space-y-8">
    <!-- 1. 顶部的 Header: 标题和操作按钮 -->
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">
          Account Overview
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
    />

    <!-- 4. 子页面渲染出口 -->
    <div class="content-below-tabs">
      <NuxtPage />
    </div>
  </div>
</template>
