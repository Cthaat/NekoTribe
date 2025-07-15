<script setup lang="ts">
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
// 1. 导入所有这个组件需要的依赖项
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Progress } from '@/components/ui/progress';
import { ref } from 'vue';
import {
  ArrowUp,
  ArrowDown,
  User,
  Mail,
  MapPin,
  MoreHorizontal
} from 'lucide-vue-next';
import type { PropType } from 'vue';
import { modal } from '#build/ui';

// 2. 为 props 定义清晰的 TypeScript 类型
interface UserData {
  name: string;
  title: string;
  location: string;
  email: string;
  avatar: string;
  stats: {
    earnings: number;
    projects: number;
    successRate: number;
  };
  profileCompletion: number;
}

interface TabItem {
  name: string;
  to: string;
}

// 3. 使用 defineProps 接收从父组件传递过来的数据
defineProps({
  user: {
    type: Object as PropType<UserData>,
    required: true
  },
  accountTabs: {
    type: Array as PropType<TabItem[]>,
    required: true
  }
});

const tabValue = defineModel<string>();
</script>

<template>
  <!-- 整个组件的最外层是一个 Card -->
  <Card>
    <!-- a. 卡片内容区，只包含需要内边距 (p-6) 的用户信息 -->
    <CardContent class="p-6">
      <div
        class="flex flex-col sm:flex-row items-start gap-6"
      >
        <!-- 头像 -->
        <Avatar class="w-24 h-24 border">
          <AvatarImage
            :src="user.avatar"
            :alt="user.name"
          />
          <AvatarFallback>{{
            user.name.slice(0, 2).toUpperCase()
          }}</AvatarFallback>
        </Avatar>

        <!-- 右侧的所有信息，使用 space-y-4 来创建垂直间距 -->
        <div class="flex-1 space-y-4">
          <!-- 用户名和操作按钮 -->
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-xl font-semibold">
                {{ user.name }}
              </h2>
              <div
                class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-muted-foreground mt-1"
              >
                <span class="flex items-center gap-1.5"
                  ><User class="w-4 h-4" />{{
                    user.title
                  }}</span
                >
                <span class="flex items-center gap-1.5"
                  ><MapPin class="w-4 h-4" />{{
                    user.location
                  }}</span
                >
                <span class="flex items-center gap-1.5"
                  ><Mail class="w-4 h-4" />{{
                    user.email
                  }}</span
                >
              </div>
            </div>
            <div class="flex items-center space-x-2">
              <Button variant="outline">Follow</Button>
              <Button>Hire Me</Button>
              <Button variant="ghost" size="icon"
                ><MoreHorizontal class="w-4 h-4"
              /></Button>
            </div>
          </div>

          <!-- 分割线 -->
          <div class="border-t"></div>

          <!-- 统计数据和进度条 -->
          <div
            class="flex flex-col sm:flex-row items-center gap-4"
          >
            <div class="flex-1 grid grid-cols-3 gap-4">
              <div class="text-center">
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  <ArrowUp class="w-4 h-4 text-green-500" />
                  ${{
                    user.stats.earnings.toLocaleString()
                  }}
                </p>
                <p class="text-xs text-muted-foreground">
                  Earnings
                </p>
              </div>
              <div class="text-center">
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  <ArrowDown class="w-4 h-4 text-red-500" />
                  {{ user.stats.projects }}
                </p>
                <p class="text-xs text-muted-foreground">
                  Projects
                </p>
              </div>
              <div class="text-center">
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  <ArrowUp class="w-4 h-4 text-green-500" />
                  %{{ user.stats.successRate }}
                </p>
                <p class="text-xs text-muted-foreground">
                  Success Rate
                </p>
              </div>
            </div>
            <div class="w-full sm:w-1/3">
              <label
                for="completion"
                class="text-sm font-medium"
                >Profile Completion</label
              >
              <div class="flex items-center gap-2">
                <Progress
                  :model-value="user.profileCompletion"
                  class="w-full"
                />
                <span class="font-semibold text-sm"
                  >{{ user.profileCompletion }}%</span
                >
              </div>
            </div>
          </div>
        </div>
      </div>
    </CardContent>
  </Card>
  <!-- b. 选项卡导航，作为 Card 的直接子元素，以实现正确的边框样式 -->
  <div
    class="inline-flex h-10 items-center justify-center rounded-full bg-muted p-1 text-muted-foreground"
  >
    <Tabs default-value="overview" class="w-full">
      <TabsList>
        <TabsTrigger
          v-for="tab in accountTabs"
          :value="tab.name"
          class="inline-flex items-center justify-center whitespace-nowrap rounded-full px-3 py-1.5 text-sm font-medium ring-offset-background transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          active-class="bg-background text-foreground shadow-sm"
        >
          <NuxtLink
            :key="tab.name"
            :to="tab.to"
            :onclick="() => (tabValue = tab.name)"
          >
            {{ tab.name }}
          </NuxtLink>
        </TabsTrigger>
      </TabsList>
    </Tabs>
  </div>
</template>
