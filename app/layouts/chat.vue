<script setup lang="ts">
import AppSidebar from '@/components/AppSidebar.vue';
import MobileTabBar from '@/components/MobileTabBar.vue';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';

const { t } = useAppLocale();
</script>

<template>
  <div class="flex h-dvh min-h-dvh w-full flex-col overflow-hidden bg-[var(--shell-frame)] text-foreground">
    <header class="flex h-[54px] shrink-0 items-center justify-between bg-background/70 px-4 backdrop-blur-xl md:hidden">
      <h1 class="text-base font-semibold tracking-tight">{{ t('nav.main.chat') }}</h1>
      <div class="flex items-center gap-1.5">
        <LanguageTriggerIcon />
        <ColorModeIcon />
      </div>
    </header>
    <div class="flex min-h-0 w-full flex-1">
      <AppSidebar class="hidden h-dvh shrink-0 md:flex" />

      <main data-page-content class="min-h-0 min-w-0 flex-1 overflow-hidden bg-background pb-20 md:my-2 md:mr-2 md:h-[calc(100dvh-16px)] md:rounded-[28px] md:p-3">
        <slot />
      </main>
    </div>

    <MobileTabBar />
  </div>
</template>
