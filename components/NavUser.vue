<script setup lang="ts">
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
import { usePreferenceStore } from '~/stores/user'; // 导入 store
import { apiFetch } from '@/composables/useApi';
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

async function handleLogout() {
  if (isLoading.value) return; // 防止重复点击

  isLoading.value = true;
  try {
    preferenceStore.resetToDefaults(); // 重置用户偏好设置
    await apiFetch('/api/v1/auth/logout', {
      method: 'GET'
    });
    toast('退出登录成功，正在跳转到登录页面...');
    console.log(
      'User logged out successfully',
      localePath('/auth/login')
    );
    navigateTo(localePath('/auth/login'));
  } catch (error) {
    toast.error('退出登录失败，请重试。');
  } finally {
    // 无论成功与否，最终都将加载状态设为 false
    // （虽然成功后会重定向，但这是个好习惯）
    isLoading.value = false;
  }
}

const { isMobile } = useSidebar();
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
            <Avatar class="h-8 w-8 rounded-lg">
              <AvatarImage
                :src="user.avatar"
                :alt="user.name"
              />
              <AvatarFallback class="rounded-lg">
                CN
              </AvatarFallback>
            </Avatar>
            <div
              class="grid flex-1 text-left text-sm leading-tight"
            >
              <span class="truncate font-medium">{{
                user.name
              }}</span>
              <span class="truncate text-xs">{{
                user.email
              }}</span>
            </div>
            <ChevronsUpDown class="ml-auto size-4" />
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
              <Avatar class="h-8 w-8 rounded-lg">
                <AvatarImage
                  :src="user.avatar"
                  :alt="user.name"
                />
                <AvatarFallback class="rounded-lg">
                  CN
                </AvatarFallback>
              </Avatar>
              <div
                class="grid flex-1 text-left text-sm leading-tight"
              >
                <span class="truncate font-semibold">{{
                  user.name
                }}</span>
                <span class="truncate text-xs">{{
                  user.email
                }}</span>
              </div>
            </div>
          </DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuGroup>
            <DropdownMenuItem>
              <Sparkles />
              Upgrade to Pro
            </DropdownMenuItem>
          </DropdownMenuGroup>
          <DropdownMenuSeparator />
          <DropdownMenuGroup>
            <DropdownMenuItem>
              <BadgeCheck />
              Account
            </DropdownMenuItem>
            <DropdownMenuItem>
              <CreditCard />
              Billing
            </DropdownMenuItem>
            <DropdownMenuItem
              @select="
                () =>
                  navigateTo(
                    localePath('/user/notifications')
                  )
              "
            >
              <Bell />
              Notifications
            </DropdownMenuItem>
          </DropdownMenuGroup>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            @select="handleLogout"
            :disabled="isLoading"
          >
            <LogOut class="mr-2 h-4 w-4" />
            Log out
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </SidebarMenuItem>
  </SidebarMenu>
</template>
