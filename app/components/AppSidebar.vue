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
  Award,
  Cat,
  Flame,
  Shield,
  Users,
  MessageSquare
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
const route = useRoute();
const { t } = useAppLocale();

const preferenceStore = usePreferenceStore();

const userId = computed(
  () => preferenceStore.preferences.user.id
);

const baseNavData = computed(() => ({
  user: {
    name:
      preferenceStore.preferences.user.name ||
      t('nav.user.fallbackName'),
    email:
      preferenceStore.preferences.user.email ||
      t('nav.user.fallbackEmail'),
    avatar:
      preferenceStore.preferences.user.avatarUrl ||
      '/avatars/shadcn.jpg'
  },
  navMain: [
    {
      title: t('nav.main.trending'),
      url: `/tweet/trending/${userId.value}`,
      icon: Flame
    },
    {
      title: t('nav.main.tweet'),
      url: `/tweet/home/${userId.value}`,
      icon: Cat,
      items: [
        {
          title: t('nav.main.home'),
          url: `/tweet/home/${userId.value}`
        },
        {
          title: t('nav.main.myTweets'),
          url: `/tweet/my_tweets/${userId.value}`
        },
        {
          title: t('nav.main.manageTweets'),
          url: 'account-posts'
        },
        {
          title: t('nav.main.mention'),
          url: `/tweet/mention/${userId.value}`
        },
        {
          title: t('nav.main.bookmark'),
          url: `/tweet/bookmark/${userId.value}`
        }
      ]
    },
    {
      title: t('nav.main.meow'),
      url: 'meow',
      icon: Send
    },
    {
      title: t('nav.main.groups'),
      url: '/groups/discover',
      icon: Users,
      items: [
        {
          title: t('nav.main.discoverGroups'),
          url: '/groups/discover'
        },
        { title: t('nav.main.myGroups'), url: '/groups/my' },
        {
          title: t('nav.main.groupPosts'),
          url: '/groups/posts'
        },
        { title: t('nav.main.invites'), url: '/groups/invites' }
      ]
    },
    {
      title: t('nav.main.chat'),
      url: '/chat',
      icon: MessageSquare
    },
    {
      title: t('nav.main.account'),
      url: 'account-overview', // 使用路由名称
      icon: Settings2,
      items: [
        { title: t('account.tabs.overview'), url: 'account-overview' },
        { title: t('account.tabs.settings'), url: 'account-settings' },
        { title: t('account.tabs.profile'), url: 'account-profile' },
        { title: t('account.tabs.posts'), url: 'account-posts' },
        {
          title: t('account.tabs.appearance'),
          url: 'account-appearance'
        },
        { title: t('account.tabs.security'), url: 'account-security' },
        { title: t('account.tabs.active'), url: 'account-active' },
        {
          title: t('account.tabs.statements'),
          url: 'account-statements'
        }
      ]
    },
    {
      title: t('nav.main.moderation'),
      url: '/moderation/content',
      icon: Shield,
      items: [
        { title: t('nav.main.content'), url: '/moderation/content' },
        { title: t('nav.main.users'), url: '/moderation/users' },
        { title: t('nav.main.reports'), url: '/moderation/reports' },
        { title: t('nav.main.settings'), url: '/moderation/settings' }
      ]
    }
  ],
  navSecondary: [
    { title: t('nav.secondary.support'), url: '#', icon: LifeBuoy },
    { title: t('nav.secondary.feedback'), url: '#', icon: Send }
  ],
  projects: [
    { name: t('nav.projects.design'), url: '#', icon: Frame },
    { name: t('nav.projects.sales'), url: '#', icon: PieChart },
    { name: t('nav.projects.travel'), url: '#', icon: Map }
  ]
}));

interface LocalizedMenuItem {
  url: string;
}

// 3. ✨ 创建一个 computed 属性，它会动态地生成包含本地化 URL 的完整导航数据
const localizedNav = computed(() => {
  // 一个可复用的辅助函数，用于处理单个菜单项
  const processMenuItem = (item: LocalizedMenuItem) => {
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
    navMain: baseNavData.value.navMain.map(mainItem => ({
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
    navSecondary: baseNavData.value.navSecondary.map(item => ({
      ...item,
      url: processMenuItem(item)
    })),

    // 处理 projects，它也没有嵌套
    projects: baseNavData.value.projects.map(project => ({
      ...project,
      url: processMenuItem(project)
    }))
  };
});

const navMainWithActiveState = computed(() => {
  const currentPath = route.path;

  return localizedNav.value.navMain.map(mainItem => {
    const selfActive = currentPath === mainItem.url;
    const childActive = mainItem.items?.some(
      subItem => currentPath === subItem.url
    );

    return {
      ...mainItem,
      isActive: selfActive || childActive
    };
  });
});
</script>

<template>
  <Sidebar v-bind="props">
    <SidebarHeader>
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton size="lg" as-child>
            <NuxtLink :to="localePath('/')">
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
                  >{{ t('app.brand.name') }}</span
                >
                <span
                  class="truncate text-xs justify-center"
                  >{{ t('app.brand.tagline') }}</span
                >
              </div>
            </NuxtLink>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    </SidebarHeader>
    <SidebarContent>
      <NavMain :items="navMainWithActiveState" />
      <!-- TODO： 后续可以开发新功能 -->
      <!-- <NavProjects :projects="localizedNav.projects" /> -->
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

