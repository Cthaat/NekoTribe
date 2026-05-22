<script setup lang="ts">
import AppSidebar from '@/components/AppSidebar.vue';
import AppGlobalSearch from '@/components/AppGlobalSearch.vue';
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger
} from '@/components/ui/sidebar';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
</script>

<template>
  <SidebarProvider class="h-dvh min-h-0 w-full overflow-hidden overflow-x-clip">
    <AppSidebar />
    <SidebarInset
      class="flex h-dvh min-h-0 max-h-dvh min-w-0 flex-col overflow-hidden overflow-x-clip md:h-[calc(100dvh_-_1rem)] md:max-h-[calc(100dvh_-_1rem)]"
    >
      <header
        class="sticky top-0 z-30 flex h-12 shrink-0 items-center justify-between gap-2 border-b border-border/60 bg-background/80 px-3 backdrop-blur supports-[backdrop-filter]:bg-background/60"
      >
        <div class="flex items-center gap-2">
          <SidebarTrigger class="-ml-1" />
        </div>
        <div class="hidden min-w-0 flex-1 sm:block">
          <AppGlobalSearch class="mx-auto max-w-md" />
        </div>
        <div class="flex items-center gap-1">
          <LanguageTriggerIcon />
          <ColorModeIcon />
        </div>
      </header>
      <main class="min-h-0 flex-1 overflow-hidden">
        <slot />
      </main>
    </SidebarInset>
  </SidebarProvider>
</template>
