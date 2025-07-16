<script setup lang="ts">
import {
  BookOpen,
  Bot,
  Command,
  Frame,
  LifeBuoy,
  Map,
  PieChart,
  Send,
  Settings2,
  SquareTerminal,
  Award
} from 'lucide-vue-next';
import NavMain from '@/components/NavMain.vue';
import NavProjects from '@/components/NavProjects.vue';
import NavSecondary from '@/components/NavSecondary.vue';
import NavUser from '@/components/NavUser.vue';
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  type SidebarProps
} from '@/components/ui/sidebar';
import { usePreferenceStore } from '~/stores/user'; // 导入 store

const props = withDefaults(defineProps<SidebarProps>(), {
  variant: 'inset'
});

const localePath = useLocalePath();

console.log('Locale path:', localePath('account-overview'));

const preferenceStore = usePreferenceStore();

const baseNavData = {
  user: {
    name:
      preferenceStore.preferences.user.displayName ||
      'shadcn',
    email:
      preferenceStore.preferences.user.email ||
      'm@example.com',
    avatar:
      preferenceStore.preferences.user.avatarUrl ||
      '/avatars/shadcn.jpg'
  },
  navMain: [
    {
      title: 'Playground',
      url: '#',
      icon: SquareTerminal,
      isActive: true,
      items: [
        {
          title: 'History',
          url: '#'
        },
        {
          title: 'Starred',
          url: '#'
        },
        {
          title: 'Settings',
          url: '#'
        }
      ]
    },
    {
      title: 'Documentation',
      url: '#',
      icon: BookOpen,
      items: [
        {
          title: 'Introduction',
          url: '#'
        },
        {
          title: 'Get Started',
          url: '#'
        },
        {
          title: 'Tutorials',
          url: '#'
        },
        {
          title: 'Changelog',
          url: '#'
        }
      ]
    },
    {
      title: 'Account',
      url: 'account-overview', // 使用路由名称
      icon: Settings2,
      items: [
        { title: 'Overview', url: 'account-overview' },
        { title: 'Settings', url: 'account-settings' },
        { title: 'Profile', url: 'account-profile' },
        { title: 'Appearance', url: 'account-appearance' },
        { title: 'Security', url: 'account-security' },
        { title: 'Active', url: 'account-active' },
        { title: 'Statements', url: 'account-statements' }
      ]
    }
  ],
  navSecondary: [
    { title: 'Support', url: '#', icon: LifeBuoy },
    { title: 'Feedback', url: '#', icon: Send }
  ],
  projects: [
    { name: 'Design Engineering', url: '#', icon: Frame },
    { name: 'Sales & Marketing', url: '#', icon: PieChart },
    { name: 'Travel', url: '#', icon: Map }
  ]
};

// 3. ✨ 创建一个 computed 属性，它会动态地生成包含本地化 URL 的完整导航数据
const localizedNav = computed(() => {
  // 一个可复用的辅助函数，用于处理单个菜单项
  const processMenuItem = (item: any) => {
    // 如果 url 是 '#' 或外部链接，则不处理，直接返回
    if (
      item.url.startsWith('#') ||
      item.url.startsWith('http')
    ) {
      return item.url;
    }
    // 否则，使用 localePath 进行本地化
    return localePath(item.url);
  };

  return {
    // 处理 navMain，它有嵌套的 items
    navMain: baseNavData.navMain.map(mainItem => ({
      ...mainItem,
      url: processMenuItem(mainItem),
      items: mainItem.items
        ? mainItem.items.map(subItem => ({
            ...subItem,
            url: processMenuItem(subItem)
          }))
        : undefined
    })),

    // 处理 navSecondary，它没有嵌套
    navSecondary: baseNavData.navSecondary.map(item => ({
      ...item,
      url: processMenuItem(item)
    })),

    // 处理 projects，它也没有嵌套
    projects: baseNavData.projects.map(project => ({
      ...project,
      url: processMenuItem(project)
    }))
  };
});

console.log('Localized nav data:', localizedNav.value);
</script>

<template>
  <Sidebar v-bind="props">
    <SidebarHeader>
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton size="lg" as-child>
            <NuxtLink :to="$localePath('/')">
              <div
                class="flex aspect-square size-8 items-center justify-center rounded-lg bg-sidebar-primary text-sidebar-primary-foreground"
              >
                <Command class="size-4" />
              </div>
              <div
                class="grid flex-1 text-left text-sm leading-tight"
              >
                <span
                  class="truncate font-medium justify-center"
                  >NekoTribe</span
                >
                <span
                  class="truncate text-xs justify-center"
                  >Edge Walker</span
                >
              </div>
            </NuxtLink>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    </SidebarHeader>
    <SidebarContent>
      <NavMain :items="localizedNav.navMain" />
      <NavProjects :projects="localizedNav.projects" />
      <NavSecondary
        :items="localizedNav.navSecondary"
        class="mt-auto"
      />
    </SidebarContent>
    <SidebarFooter>
      <NavUser :user="baseNavData.user" />
    </SidebarFooter>
  </Sidebar>
</template>
