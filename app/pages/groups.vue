<script setup lang="ts">
import { ref, computed } from 'vue';
import {
  Users,
  Compass,
  UserCheck,
  Bell,
  FileText
} from 'lucide-vue-next';
import {
  Tabs,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import { Button } from '@/components/ui/button';

// 定义页面 meta
definePageMeta({
  layout: 'default'
});

// 当前选中的标签
const activeTab = ref('discover');
const { t } = useAppLocale();
const localePath = useLocalePath();

// 导航标签配置
const tabs = [
  {
    value: 'discover',
    labelKey: 'groups.tabs.discover',
    icon: Compass,
    path: '/groups/discover'
  },
  {
    value: 'my',
    labelKey: 'groups.tabs.my',
    icon: UserCheck,
    path: '/groups/my'
  },
  {
    value: 'posts',
    labelKey: 'groups.tabs.posts',
    icon: FileText,
    path: '/groups/posts'
  },
  {
    value: 'invites',
    labelKey: 'groups.tabs.invites',
    icon: Bell,
    path: '/groups/invites'
  }
];

// 处理标签切换
const handleTabChange = (value: string | number) => {
  const strValue = String(value);
  activeTab.value = strValue;
  const tab = tabs.find(t => t.value === strValue);
  if (tab) {
    navigateTo(localePath(tab.path));
  }
};

// 根据当前路由设置活动标签
const route = useRoute();
const currentPath = computed(() => route.path);

// 初始化时根据路由设置标签
onMounted(() => {
  const currentTab = tabs.find(t =>
    currentPath.value.includes(t.value)
  );
  if (currentTab) {
    activeTab.value = currentTab.value;
  }
});

// 监听路由变化
watch(currentPath, newPath => {
  const currentTab = tabs.find(t =>
    newPath.includes(t.value)
  );
  if (currentTab) {
    activeTab.value = currentTab.value;
  }
});
</script>

<template>
  <div class="container mx-auto py-6 px-4 max-w-7xl">
    <!-- 页面标题 -->
    <div class="flex items-center justify-between mb-6">
      <div class="flex items-center gap-3">
        <div class="p-2 bg-primary/10 rounded-lg">
          <Users class="h-6 w-6 text-primary" />
        </div>
        <div>
          <h1 class="text-2xl font-bold">{{ t('groups.title') }}</h1>
          <p class="text-sm text-muted-foreground">
            {{ t('groups.description') }}
          </p>
        </div>
      </div>
    </div>

    <!-- 标签导航 -->
    <Tabs
      :model-value="activeTab"
      class="mb-6"
      @update:model-value="handleTabChange"
    >
      <TabsList
        class="grid w-full grid-cols-4 lg:w-auto lg:inline-grid"
      >
        <TabsTrigger
          v-for="tab in tabs"
          :key="tab.value"
          :value="tab.value"
          class="gap-2"
        >
          <component :is="tab.icon" class="h-4 w-4" />
          <span class="hidden sm:inline">{{
            t(tab.labelKey)
          }}</span>
        </TabsTrigger>
      </TabsList>
    </Tabs>

    <!-- 子页面内容 -->
    <NuxtPage />
  </div>
</template>
