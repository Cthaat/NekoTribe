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
  <div
    class="min-h-[calc(100dvh-4rem)] overflow-y-auto px-4 py-5"
  >
    <div class="mx-auto max-w-7xl space-y-5">
      <!-- 页面标题 -->
      <div
        class="flex flex-col gap-4 rounded-lg border bg-card/70 p-4 shadow-sm sm:flex-row sm:items-center sm:justify-between"
      >
        <div class="flex items-center gap-3">
          <div class="rounded-md bg-primary/10 p-2">
            <Shield class="h-5 w-5 text-primary" />
          </div>
          <div>
            <h1 class="text-xl font-semibold tracking-normal">
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
          class="overflow-x-auto"
        >
          <TabsList class="w-full sm:w-auto">
            <TabsTrigger
              v-for="tab in tabs"
              :key="tab.value"
              :value="tab.value"
              class="gap-2"
            >
              <component :is="tab.icon" class="h-4 w-4" />
              <span>{{ t(tab.labelKey) }}</span>
            </TabsTrigger>
          </TabsList>
        </Tabs>
      </div>

      <!-- 子页面内容 -->
      <NuxtPage />
    </div>
  </div>
</template>
