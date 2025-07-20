<script setup lang="ts">
import AppSidebar from '@/components/AppSidebar.vue';
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator
} from '@/components/ui/breadcrumb';
import { Separator } from '@/components/ui/separator';
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger
} from '@/components/ui/sidebar';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
import { Search } from 'lucide-vue-next'; // 引入搜索图标

const searchQuery = ref('');
const description =
  'An inset sidebar with secondary navigation.';
const iframeHeight = '800px';
</script>

<template>
  <SidebarProvider>
    <AppSidebar />
    <SidebarInset>
      <header
        class="flex h-16 shrink-0 items-center gap-4 px-4"
      >
        <div class="flex items-center gap-2">
          <SidebarTrigger class="-ml-1" />
          <Separator
            orientation="vertical"
            class="data-[orientation=vertical]:h-4"
          />
        </div>
        <div class="flex-1">
          <div
            class="relative flex items-center w-full transition-colors duration-200 ease-in-out bg-transparent border border-neutral-800 rounded-full hover:bg-neutral-900 focus-within:bg-neutral-900 focus-within:border-neutral-700"
          >
            <!-- 搜索图标 -->
            <Search
              class="w-5 h-5 absolute left-4 text-gray-500"
            />
            <input
              v-model="searchQuery"
              type="text"
              placeholder="Search"
              class="w-full h-full bg-transparent border-0 rounded-full pl-12 pr-4 py-2 text-neutral-200 placeholder:text-neutral-500 focus:outline-none focus:ring-0"
            />
          </div>
        </div>

        <div class="flex items-center gap-2">
          <LanguageTriggerIcon />
          <ColorModeIcon />
        </div>
      </header>
      <slot />
    </SidebarInset>
  </SidebarProvider>
</template>
