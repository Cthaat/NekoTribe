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
import { ScrollArea } from '@/components/ui/scroll-area';

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
  <ScrollArea class="h-[calc(100dvh-4rem)] mobile-scroll-safe">
    <div class="mx-auto max-w-7xl space-y-5 px-3 py-3 sm:px-4 sm:py-4 lg:px-0 lg:py-0">
      <section
        class="flex flex-col gap-4 rounded-xl border border-border/60 bg-card p-4 shadow-none sm:flex-row sm:items-center sm:justify-between sm:p-5"
      >
        <div class="flex items-center gap-3">
          <span
            class="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary ring-1 ring-primary/20"
          >
            <Shield class="h-5 w-5" />
          </span>
          <div class="min-w-0">
            <h1 class="text-xl font-semibold tracking-tight">
              {{ t('moderation.title') }}
            </h1>
            <p class="mt-0.5 text-sm text-muted-foreground">
              {{ t('moderation.description') }}
            </p>
          </div>
        </div>

        <Tabs
          :model-value="activeTab"
          @update:model-value="handleTabChange"
          class="w-full overflow-x-auto sm:w-auto"
        >
          <TabsList class="grid w-full grid-cols-4 sm:inline-flex sm:w-auto sm:min-w-0">
            <TabsTrigger
              v-for="tab in tabs"
              :key="tab.value"
              :value="tab.value"
              class="shrink-0 gap-2"
            >
              <component :is="tab.icon" class="h-4 w-4" />
              <span class="hidden sm:inline">{{ t(tab.labelKey) }}</span>
            </TabsTrigger>
          </TabsList>
        </Tabs>
      </section>

      <NuxtPage />
    </div>
  </ScrollArea>
</template>
