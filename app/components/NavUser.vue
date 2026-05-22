<script setup lang="ts">
import { computed } from 'vue';
import {
  BadgeCheck,
  Bell,
  ChevronsUpDown,
  CreditCard,
  LogOut,
  Sparkles
} from 'lucide-vue-next';

import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar
} from '@/components/ui/sidebar';
import { usePreferenceStore } from '~/stores/user';
import { v2LogoutCurrent } from '@/services';
import { toast } from 'vue-sonner';

const localePath = useLocalePath();

const props = defineProps<{
  user: {
    name: string;
    email: string;
    avatar: string;
  };
}>();

import { navigateTo } from '#app';
const preferenceStore = usePreferenceStore();
const isLoading = ref(false);
const { t } = useAppLocale();

const userInitials = computed(() => {
  const name = props.user.name || props.user.email || 'NT';
  return name.slice(0, 2).toUpperCase();
});

async function handleLogout() {
  if (isLoading.value) return;

  isLoading.value = true;
  try {
    preferenceStore.resetToDefaults();
    await v2LogoutCurrent();
    toast(t('nav.user.logoutSuccess'));
    navigateTo(localePath('/auth/login'));
  } catch (error) {
    toast.error(t('nav.user.logoutError'));
  } finally {
    isLoading.value = false;
  }
}

const { isMobile } = useSidebar();

function goToUserMenuRoute(routeName: string): void {
  void navigateTo(localePath(routeName));
}

function goToNotifications(): void {
  void navigateTo(
    localePath(
      `/user/${preferenceStore.preferences.user.id}/notifications`
    )
  );
}
</script>

<template>
  <SidebarMenu>
    <SidebarMenuItem>
      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <SidebarMenuButton
            size="lg"
            class="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
          >
            <Avatar class="h-8 w-8 rounded-lg ring-1 ring-sidebar-border">
              <AvatarImage
                :src="user.avatar"
                :alt="user.name"
              />
              <AvatarFallback
                class="rounded-lg bg-primary/10 text-xs font-semibold text-primary"
              >
                {{ userInitials }}
              </AvatarFallback>
            </Avatar>
            <div
              class="grid flex-1 text-left text-sm leading-tight"
            >
              <span class="truncate font-medium">{{
                user.name
              }}</span>
              <span class="truncate text-xs text-muted-foreground">{{
                user.email
              }}</span>
            </div>
            <ChevronsUpDown class="ml-auto size-4 text-muted-foreground" />
          </SidebarMenuButton>
        </DropdownMenuTrigger>

        <DropdownMenuContent
          class="w-[--reka-dropdown-menu-trigger-width] min-w-56 rounded-lg"
          :side="isMobile ? 'bottom' : 'right'"
          align="end"
          :side-offset="4"
        >
          <DropdownMenuLabel class="p-0 font-normal">
            <div
              class="flex items-center gap-2 px-1 py-1.5 text-left text-sm"
            >
              <Avatar class="h-8 w-8 rounded-lg ring-1 ring-border">
                <AvatarImage
                  :src="user.avatar"
                  :alt="user.name"
                />
                <AvatarFallback
                  class="rounded-lg bg-primary/10 text-xs font-semibold text-primary"
                >
                  {{ userInitials }}
                </AvatarFallback>
              </Avatar>
              <div
                class="grid flex-1 text-left text-sm leading-tight"
              >
                <span class="truncate font-semibold">{{
                  user.name
                }}</span>
                <span class="truncate text-xs text-muted-foreground">{{
                  user.email
                }}</span>
              </div>
            </div>
          </DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuGroup>
            <DropdownMenuItem
              @select="goToUserMenuRoute('account-pro')"
            >
              <Sparkles class="h-4 w-4" />
              {{ t('nav.user.upgrade') }}
            </DropdownMenuItem>
          </DropdownMenuGroup>
          <DropdownMenuSeparator />
          <DropdownMenuGroup>
            <DropdownMenuItem
              @select="goToUserMenuRoute('account-overview')"
            >
              <BadgeCheck class="h-4 w-4" />
              {{ t('nav.user.account') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              @select="goToUserMenuRoute('account-billing')"
            >
              <CreditCard class="h-4 w-4" />
              {{ t('nav.user.billing') }}
            </DropdownMenuItem>
            <DropdownMenuItem @select="goToNotifications">
              <Bell class="h-4 w-4" />
              {{ t('nav.user.notifications') }}
            </DropdownMenuItem>
          </DropdownMenuGroup>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            class="text-destructive focus:text-destructive"
            :disabled="isLoading"
            @select="handleLogout"
          >
            <LogOut class="h-4 w-4" />
            {{ t('nav.user.logout') }}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </SidebarMenuItem>
  </SidebarMenu>
</template>
