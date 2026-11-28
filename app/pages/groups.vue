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
const isGroupDetailRoute = computed(() => {
  const slug = route.params.slug;
  return typeof slug === 'string' && slug.trim().length > 0;
});

function syncActiveTab(path: string): void {
  const normalized = path.replace(/^\/(zh|en)(?=\/|$)/, '');
  const currentTab = tabs.find(t => normalized === t.path || normalized.startsWith(`${t.path}/`));
  if (currentTab) {
    activeTab.value = currentTab.value;
  }
}

// 初始化时根据路由设置标签
onMounted(() => {
  syncActiveTab(currentPath.value);
});

// 监听路由变化
watch(currentPath, newPath => {
  syncActiveTab(newPath);
});
</script>

<template>
  <div class="mx-auto max-w-[920px] overflow-x-clip px-3 py-4 sm:px-5 sm:py-6">
    <!-- 页面标题与分段导航仅在群组目录/列表页显示 -->
    <template v-if="!isGroupDetailRoute">
      <div class="mb-5 flex min-w-0 items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <div class="flex size-10 items-center justify-center rounded-2xl bg-[var(--primary-soft)]">
            <Users class="h-5 w-5 text-primary" />
          </div>
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-foreground">{{ t('groups.title') }}</h1>
            <p class="text-sm text-muted-foreground">
              {{ t('groups.description') }}
            </p>
          </div>
        </div>
      </div>

      <!-- 胶囊分段导航 -->
      <Tabs
        :model-value="activeTab"
        class="mb-6"
        @update:model-value="handleTabChange"
      >
        <TabsList
          class="grid h-auto w-full grid-cols-4 rounded-full bg-secondary p-1 [--tab-inset:4px] [--tab-fill:var(--primary)] sm:inline-flex sm:w-auto sm:gap-1"
        >
          <TabsTrigger
            v-for="tab in tabs"
            :key="tab.value"
            :value="tab.value"
            :aria-label="t(tab.labelKey)"
            class="gap-1.5 rounded-full border-0 px-4 py-2 text-sm font-medium text-muted-foreground shadow-none transition-colors hover:text-foreground data-[state=active]:font-semibold data-[state=active]:text-primary-foreground dark:data-[state=active]:border-transparent dark:data-[state=active]:text-primary-foreground"
          >
            <component
              :is="tab.icon"
              class="h-4 w-4 shrink-0"
            />
            <span class="hidden sm:inline">{{
              t(tab.labelKey)
            }}</span>
          </TabsTrigger>
        </TabsList>
      </Tabs>
    </template>

    <!-- 子页面内容 -->
    <NuxtPage />
  </div>
</template>
