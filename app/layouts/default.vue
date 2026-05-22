<script setup lang="ts">
import AppSidebar from '@/components/AppSidebar.vue';
import AppGlobalSearch from '@/components/AppGlobalSearch.vue';
import { Separator } from '@/components/ui/separator';
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger
} from '@/components/ui/sidebar';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
</script>

<template>
  <SidebarProvider class="min-h-dvh w-full overflow-x-clip">
    <AppSidebar />
    <SidebarInset class="flex min-h-dvh min-w-0 flex-col overflow-x-clip">
      <header
        class="sticky top-0 z-30 flex h-14 shrink-0 items-center gap-2 border-b border-border/60 bg-background/80 px-3 backdrop-blur supports-[backdrop-filter]:bg-background/60 sm:gap-4 sm:px-4"
      >
        <div class="flex items-center gap-2">
          <SidebarTrigger class="-ml-1" />
          <Separator
            orientation="vertical"
            class="data-[orientation=vertical]:h-4"
          />
        </div>
        <div class="min-w-0 flex-1">
          <AppGlobalSearch
            class="max-w-2xl max-[420px]:[&_button]:hidden max-[420px]:[&_input]:pr-3"
          />
        </div>

        <div class="flex items-center gap-1">
          <LanguageTriggerIcon />
          <ColorModeIcon />
        </div>
      </header>
      <main class="min-w-0 flex-1 overflow-x-clip">
        <slot />
      </main>
    </SidebarInset>
  </SidebarProvider>
</template>
