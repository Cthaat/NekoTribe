<script setup lang="ts">
import { ref, computed } from 'vue';
import {
  Shield,
  FileText,
  Users,
  Settings,
  BarChart3
} from 'lucide-vue-next';
import {
  Tabs,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';

const { t } = useAppLocale();
const localePath = useLocalePath();

// 定义页面 meta
definePageMeta({
  layout: 'default'
});

// 当前选中的标签
const activeTab = ref('content');

// 导航标签配置
const tabs = [
  {
    value: 'content',
    labelKey: 'moderation.tabs.content',
    icon: FileText,
    path: '/moderation/content'
  },
  {
    value: 'users',
    labelKey: 'moderation.tabs.users',
    icon: Users,
    path: '/moderation/users'
  },
  {
    value: 'reports',
    labelKey: 'moderation.tabs.reports',
    icon: BarChart3,
    path: '/moderation/reports'
  },
  {
    value: 'settings',
    labelKey: 'moderation.tabs.settings',
    icon: Settings,
    path: '/moderation/settings'
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
    <div class="flex items-center gap-3 mb-6">
      <div class="p-2 bg-primary/10 rounded-lg">
        <Shield class="h-6 w-6 text-primary" />
      </div>
      <div>
        <h1 class="text-2xl font-bold">
          {{ t('moderation.title') }}
        </h1>
        <p class="text-sm text-muted-foreground">
          {{ t('moderation.description') }}
        </p>
      </div>
    </div>

    <!-- 标签导航 -->
    <Tabs
      :model-value="activeTab"
      @update:model-value="handleTabChange"
      class="mb-6"
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
