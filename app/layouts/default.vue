<script setup lang="ts">
import { computed, ref } from 'vue';
import { PawPrint, Search, X } from 'lucide-vue-next';
import AppSidebar from '@/components/AppSidebar.vue';
import AppGlobalSearch from '@/components/AppGlobalSearch.vue';
import MobileTabBar from '@/components/MobileTabBar.vue';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
import LiquidGlassIconButton from '@/components/glass/LiquidGlassIconButton.vue';

const { t } = useAppLocale();
const route = useRoute();
const localePath = useLocalePath();
const mobileSearchOpen = ref(false);

const normalizedPath = computed(() =>
  route.path.replace(/^\/(zh|en)(?=\/|$)/, '') || '/'
);

const isWideToolRoute = computed(() =>
  ['/discover', '/groups', '/account', '/moderation', '/ai/', '/about', '/meow'].some(prefix =>
    normalizedPath.value.startsWith(prefix)
  )
);

const isChatRoute = computed(() => normalizedPath.value.startsWith('/chat'));
</script>

<template>
  <div class="min-h-dvh w-full bg-[var(--shell-frame)] text-foreground overflow-x-clip">
    <!-- Mobile lightweight translucent top bar -->
    <header
      class="sticky top-0 z-30 bg-background/70 px-3 backdrop-blur-xl md:hidden"
    >
      <div class="flex h-[54px] items-center justify-between gap-2">
        <NuxtLink
          :to="localePath('/')"
          class="flex items-center gap-2 rounded-full py-1 pr-2"
          aria-label="NekoTribe"
        >
          <span class="flex size-8 items-center justify-center rounded-full bg-primary text-primary-foreground">
            <PawPrint class="size-4" />
          </span>
          <span class="text-[16px] font-semibold tracking-tight text-foreground">
            {{ t('app.brand.name') }}
          </span>
        </NuxtLink>

        <div class="flex shrink-0 items-center gap-1.5">
          <LiquidGlassIconButton
            :aria-label="t('common.search')"
            :aria-expanded="mobileSearchOpen"
            @click="mobileSearchOpen = !mobileSearchOpen"
          >
            <X v-if="mobileSearchOpen" class="size-[18px]" />
            <Search v-else class="size-[18px]" />
          </LiquidGlassIconButton>
          <LanguageTriggerIcon />
          <ColorModeIcon />
        </div>
      </div>

      <div v-if="mobileSearchOpen" class="pb-2.5">
        <AppGlobalSearch class="max-w-none" />
      </div>
    </header>

    <!-- Desktop dual-zone minimal inset shell -->
    <div class="flex min-h-dvh w-full">
      <AppSidebar class="sticky top-0 hidden h-dvh shrink-0 md:flex" />

      <main
        class="min-w-0 flex-1 bg-background pb-24 md:my-2 md:mr-2 md:min-h-[calc(100dvh-16px)] md:rounded-[28px] md:pb-8 md:overflow-x-clip"
      >
        <div
          class="mx-auto w-full"
          :class="
            isChatRoute
              ? 'max-w-[1160px]'
              : isWideToolRoute
                ? 'max-w-[920px]'
                : 'max-w-[640px]'
          "
        >
          <slot />
        </div>
      </main>
    </div>

    <MobileTabBar />
  </div>
</template>
