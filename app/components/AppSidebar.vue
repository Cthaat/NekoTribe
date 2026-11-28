<script setup lang="ts">
import { computed, ref } from 'vue';
import {
  BadgeCheck,
  Bell,
  Bookmark,
  Bot,
  BrainCircuit,
  Compass,
  CreditCard,
  Feather,
  Home,
  Info,
  LogOut,
  MessageCircle,
  MoreHorizontal,
  PawPrint,
  Settings,
  Shield,
  Sparkles,
  User,
  Users
} from 'lucide-vue-next';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import { useSelectionRail } from '@/composables/useSelectionRail';
import UserAvatar from '@/components/UserAvatar.vue';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
import { usePreferenceStore } from '~/stores/user';
import { toast } from 'vue-sonner';

const localePath = useLocalePath();
const route = useRoute();
const { t } = useAppLocale();
const preferences = usePreferenceStore();
const { list, style: railStyle } = useSelectionRail('[data-current]');
const loggingOut = ref(false);

const user = computed(() => preferences.preferences.user);
const signedIn = computed(() => preferences.isLoggedIn);
const userId = computed(() => user.value.id);
const displayName = computed(
  () => user.value.name || user.value.username || t('nav.user.fallbackName')
);
const subtitle = computed(() =>
  user.value.username
    ? `@${user.value.username}`
    : (user.value.email || t('nav.user.fallbackEmail'))
);

const primaryNav = computed(() => [
  {
    key: 'home',
    title: t('nav.main.home'),
    to: localePath('/'),
    icon: Home,
    active: route.path === localePath('/') && route.query.feed !== 'trending'
  },
  {
    key: 'discover',
    title: t('nav.main.discover'),
    to: localePath('/discover'),
    icon: Compass,
    active:
      route.path === localePath('/discover') ||
      route.path.includes('/tags/') ||
      route.path.includes('/tweet/search/') ||
      (route.path === localePath('/') && route.query.feed === 'trending')
  },
  {
    key: 'notifications',
    title: t('nav.main.notifications'),
    to: signedIn.value
      ? localePath(`/user/${userId.value}/notifications`)
      : localePath('/auth/login'),
    icon: Bell,
    active: route.path.includes('/notifications')
  },
  {
    key: 'chat',
    title: t('nav.main.chat'),
    to: localePath('/chat'),
    icon: MessageCircle,
    active: route.path.includes('/chat')
  },
  {
    key: 'groups',
    title: t('nav.main.groups'),
    to: localePath('/groups/discover'),
    icon: Users,
    active: route.path.includes('/groups')
  },
  {
    key: 'bookmarks',
    title: t('nav.main.bookmark'),
    to: localePath('/account/bookmarks'),
    icon: Bookmark,
    active:
      route.path.includes('/account/bookmarks') ||
      route.path.includes('/tweet/bookmark/')
  },
  {
    key: 'profile',
    title: t('nav.main.profile'),
    to: signedIn.value
      ? localePath(`/user/${userId.value}/profile`)
      : localePath('/account/overview'),
    icon: User,
    active: route.path.includes('/profile')
  }
]);

const isMoreActive = computed(() =>
  route.path.includes('/ai/') ||
  route.path.includes('/moderation') ||
  route.path.includes('/account/overview') ||
  route.path.includes('/account/settings') ||
  route.path.includes('/account/appearance') ||
  route.path.includes('/account/posts')
);

function go(path: string): void {
  void navigateTo(localePath(path));
}

async function handleLogout(): Promise<void> {
  if (loggingOut.value) return;
  loggingOut.value = true;
  try {
    const result = await preferences.logoutCurrentSession();
    if (!result || !preferences.isAuthCurrent(result.revision)) return;
    if (!result.ok) throw result.error;
    toast(t('nav.user.logoutSuccess'));
    void navigateTo(localePath('/auth/login'));
  } catch {
    toast.error(t('nav.user.logoutError'));
  } finally {
    loggingOut.value = false;
  }
}
</script>

<template>
  <aside
    class="flex flex-col justify-between bg-transparent px-2 py-3.5 md:w-[72px] lg:w-[220px] lg:px-3"
    aria-label="Primary navigation"
  >
    <div class="flex flex-col gap-1 overflow-y-auto">
      <!-- Brand -->
      <NuxtLink
        :to="localePath('/')"
        class="pressable mb-3 inline-flex items-center gap-2.5 self-center rounded-full px-2 py-1.5 transition-colors hover:bg-accent/70 lg:self-start lg:px-2.5"
      >
        <span class="flex size-9 items-center justify-center rounded-full bg-primary text-primary-foreground">
          <PawPrint class="size-[18px]" />
        </span>
        <span class="hidden text-[17px] font-semibold tracking-tight text-foreground lg:inline">
          {{ t('app.brand.name') }}
        </span>
      </NuxtLink>

      <!-- Social primary links -->
      <nav ref="list" :style="railStyle" class="selection-rail sidebar-rail relative isolate flex flex-col gap-1">
        <slot name="search" />
        <NuxtLink
          v-for="item in primaryNav"
          :key="item.key"
          :data-current="item.active || undefined"
          :aria-label="item.title"
          :to="item.to"
          class="pressable flex h-[42px] items-center justify-center gap-3 rounded-full px-2.5 text-[14.5px] transition-colors lg:justify-start lg:px-3.5"
          :class="
            item.active
              ? 'font-semibold text-primary'
              : 'font-medium text-muted-foreground hover:bg-accent/65 hover:text-foreground'
          "
        >
          <component
            :is="item.icon"
            class="size-5 shrink-0"
            :stroke-width="item.active ? 2.15 : 1.75"
          />
          <span class="hidden truncate lg:inline">{{ item.title }}</span>
        </NuxtLink>

        <!-- More menu (AI assistants, Moderation, Account Settings, About) -->
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <button
              type="button"
              class="pressable flex h-[42px] w-full items-center justify-center gap-3 rounded-full px-2.5 text-[14.5px] transition-colors lg:justify-start lg:px-3.5"
              :data-current="isMoreActive || undefined"
              :aria-label="t('common.more')"
              :class="
                isMoreActive
                  ? 'font-semibold text-primary'
                  : 'font-medium text-muted-foreground hover:bg-accent/65 hover:text-foreground'
              "
            >
              <MoreHorizontal
                class="size-5 shrink-0"
                :stroke-width="isMoreActive ? 2.15 : 1.75"
              />
              <span class="hidden truncate lg:inline">{{ t('common.more') }}</span>
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent side="right" align="start" class="w-56 rounded-[20px] p-1.5">
            <DropdownMenuGroup>
              <DropdownMenuItem @select="go('/ai/writing')">
                <Bot class="mr-2 size-4" />
                <span>{{ t('aiWriting.title') }}</span>
              </DropdownMenuItem>
              <DropdownMenuItem @select="go('/ai/knowledge')">
                <BrainCircuit class="mr-2 size-4" />
                <span>{{ t('aiKnowledge.title') }}</span>
              </DropdownMenuItem>
            </DropdownMenuGroup>
            <DropdownMenuSeparator />
            <DropdownMenuGroup>
              <DropdownMenuItem @select="go('/account/overview')">
                <BadgeCheck class="mr-2 size-4" />
                <span>{{ t('nav.main.account') }}</span>
              </DropdownMenuItem>
              <DropdownMenuItem @select="go('/account/posts')">
                <Feather class="mr-2 size-4" />
                <span>{{ t('nav.main.manageTweets') }}</span>
              </DropdownMenuItem>
              <DropdownMenuItem @select="go('/account/settings')">
                <Settings class="mr-2 size-4" />
                <span>{{ t('nav.main.settings') }}</span>
              </DropdownMenuItem>
            </DropdownMenuGroup>
            <DropdownMenuSeparator />
            <DropdownMenuGroup>
              <DropdownMenuItem @select="go('/moderation/content')">
                <Shield class="mr-2 size-4" />
                <span>{{ t('nav.main.moderation') }}</span>
              </DropdownMenuItem>
              <DropdownMenuItem @select="go('/about')">
                <Info class="mr-2 size-4" />
                <span>{{ t('nav.secondary.about') }}</span>
              </DropdownMenuItem>
            </DropdownMenuGroup>
          </DropdownMenuContent>
        </DropdownMenu>
      </nav>

      <!-- Compose CTA -->
      <div class="mt-3 px-0.5 lg:px-1">
        <NuxtLink
          :to="localePath('/meow')"
          class="pressable mx-auto flex h-[42px] w-[42px] items-center justify-center rounded-full bg-primary text-[14px] font-semibold text-primary-foreground transition-opacity hover:opacity-92 lg:w-full"
        >
          <Feather class="size-4 lg:hidden" />
          <span class="hidden lg:inline">{{ t('nav.main.post') }}</span>
        </NuxtLink>
      </div>
    </div>

    <!-- Bottom Utilities + Profile Pill -->
    <div class="mt-2 flex flex-col gap-2">
      <div class="flex flex-col items-center gap-1.5 lg:flex-row lg:px-2">
        <LanguageTriggerIcon />
        <ColorModeIcon />
      </div>

      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <button
            type="button"
            class="pressable flex w-full items-center justify-center gap-2.5 rounded-full p-2 text-left transition-colors hover:bg-accent/65 lg:justify-start lg:px-2.5"
          >
            <UserAvatar
              :src="user.avatarUrl"
              :name="displayName"
              :username="user.username"
              :seed="user.id"
              size="sm"
            />
            <div class="hidden min-w-0 flex-1 lg:block">
              <p class="truncate text-[13.5px] font-semibold leading-tight text-foreground">
                {{ displayName }}
              </p>
              <p class="truncate text-[12px] text-[var(--ink-tertiary)]">
                {{ subtitle }}
              </p>
            </div>
            <MoreHorizontal class="hidden size-4 shrink-0 text-muted-foreground lg:block" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent side="top" align="start" class="w-56 rounded-[20px] p-1.5">
          <DropdownMenuLabel class="px-2.5 py-2 font-normal">
            <div class="flex items-center gap-2.5">
              <UserAvatar
                :src="user.avatarUrl"
                :name="displayName"
                :username="user.username"
                :seed="user.id"
                size="sm"
              />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-semibold">{{ displayName }}</p>
                <p class="truncate text-xs text-[var(--ink-tertiary)]">{{ subtitle }}</p>
              </div>
            </div>
          </DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuItem @select="go('/account/pro')">
            <Sparkles class="mr-2 size-4" />
            <span>{{ t('nav.user.upgrade') }}</span>
          </DropdownMenuItem>
          <DropdownMenuItem @select="go('/account/overview')">
            <BadgeCheck class="mr-2 size-4" />
            <span>{{ t('nav.user.account') }}</span>
          </DropdownMenuItem>
          <DropdownMenuItem @select="go('/account/billing')">
            <CreditCard class="mr-2 size-4" />
            <span>{{ t('nav.user.billing') }}</span>
          </DropdownMenuItem>
          <DropdownMenuItem
            @select="go(signedIn ? `/user/${userId}/notifications` : '/auth/login')"
          >
            <Bell class="mr-2 size-4" />
            <span>{{ t('nav.user.notifications') }}</span>
          </DropdownMenuItem>
          <template v-if="signedIn">
            <DropdownMenuSeparator />
            <DropdownMenuItem
              class="text-destructive focus:text-destructive"
              :disabled="loggingOut"
              @select="handleLogout"
            >
              <LogOut class="mr-2 size-4" />
              <span>{{ t('nav.user.logout') }}</span>
            </DropdownMenuItem>
          </template>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  </aside>
</template>
