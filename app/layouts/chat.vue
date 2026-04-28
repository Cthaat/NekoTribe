<script setup lang="ts">
import AppSidebar from '@/components/AppSidebar.vue';
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger
} from '@/components/ui/sidebar';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
</script>

<template>
  <SidebarProvider>
    <AppSidebar />
    <SidebarInset
      class="flex flex-col h-screen overflow-hidden"
    >
      <!-- 紧凑的顶部栏 -->
      <header
        class="flex h-12 shrink-0 items-center justify-between gap-2 px-3 border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60"
      >
        <div class="flex items-center gap-2">
          <SidebarTrigger class="-ml-1" />
        </div>
        <div class="flex items-center gap-1">
          <LanguageTriggerIcon />
          <ColorModeIcon />
        </div>
      </header>
      <!-- 内容区域 - 占据剩余全部空间 -->
      <main class="flex-1 overflow-hidden">
        <slot />
      </main>
    </SidebarInset>
  </SidebarProvider>
</template>
