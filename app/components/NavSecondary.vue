<script setup lang="ts">
import type { LucideIcon } from 'lucide-vue-next';

import {
  SidebarGroup,
  SidebarGroupContent,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem
} from '@/components/ui/sidebar';

defineProps<{
  items: {
    title: string;
    url: string;
    icon: LucideIcon;
  }[];
}>();

function isPlainHref(url: string): boolean {
  return (
    url.startsWith('#') ||
    url.startsWith('http://') ||
    url.startsWith('https://') ||
    url.startsWith('mailto:')
  );
}

function isExternalHref(url: string): boolean {
  return (
    url.startsWith('http://') || url.startsWith('https://')
  );
}
</script>

<template>
  <SidebarGroup>
    <SidebarGroupContent>
      <SidebarMenu>
        <SidebarMenuItem v-for="item in items" :key="item.title">
          <SidebarMenuButton as-child size="sm">
            <a
              v-if="isPlainHref(item.url)"
              :href="item.url"
              :target="isExternalHref(item.url) ? '_blank' : undefined"
              :rel="
                isExternalHref(item.url)
                  ? 'noreferrer noopener'
                  : undefined
              "
            >
              <component :is="item.icon" />
              <span>{{ item.title }}</span>
            </a>
            <NuxtLink v-else :to="item.url">
              <component :is="item.icon" />
              <span>{{ item.title }}</span>
            </NuxtLink>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    </SidebarGroupContent>
  </SidebarGroup>
</template>
