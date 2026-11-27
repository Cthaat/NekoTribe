<script setup lang="ts">
import { computed } from 'vue';
import {
  Home,
  Languages,
  LayoutGrid,
  MessageCircle,
  Palette,
  Sparkles,
  Type,
  Users
} from 'lucide-vue-next';
import { usePreferenceStore } from '@/stores/user';
import type { GlassIntensity, LanguageCode } from '@/stores/type';
import { Button } from '@/components/ui/button';
import UserAvatar from '@/components/UserAvatar.vue';

const pref = usePreferenceStore();
const { locale, t, setAppLocale } = useAppLocale();

const theme = computed({
  get: () => pref.preferences.theme_mode,
  set: v => pref.updatePreference('theme_mode', v)
});

const glassIntensity = computed<GlassIntensity>({
  get: () => (pref.preferences.glass_intensity === 'subtle' ? 'subtle' : 'standard'),
  set: v => pref.updatePreference('glass_intensity', v)
});

const compact = computed({
  get: () => pref.preferences.compact_mode,
  set: v => pref.updatePreference('compact_mode', v)
});

const fontSize = computed({
  get: () => pref.preferences.font_size,
  set: v => pref.updatePreference('font_size', v)
});

const lang = computed({
  get: () => locale.value,
  set: (v: LanguageCode) => {
    void setAppLocale(v);
  }
});
</script>

<template>
  <div class="grid gap-4">
    <section class="bento-card grid gap-3 p-5 sm:p-6">
      <div class="text-center text-xs font-semibold tracking-wide text-muted-foreground">
        {{ t('account.appearance.previewTitle') }}
      </div>
      <div class="mx-auto w-full max-w-[304px] rounded-[28px] bg-secondary p-2.5">
        <div class="relative overflow-hidden rounded-[22px] bg-background p-3.5 pb-16">
          <div class="mx-auto mb-3 h-1.5 w-12 rounded-full bg-accent" />
          <div class="bento-card p-3.5">
            <div class="flex items-start gap-2.5">
              <UserAvatar :name="t('account.appearance.previewSampleName')" :seed="7" size="sm" />
              <div class="min-w-0 flex-1">
                <div class="flex items-center justify-between gap-2">
                  <div class="truncate text-sm font-semibold text-foreground">{{ t('account.appearance.previewSampleName') }}</div>
                  <span class="status-pill-online inline-flex shrink-0 items-center gap-1 px-2 py-0.5 text-[10px] font-semibold">
                    <span class="size-1.5 rounded-full bg-[var(--status-online-fg)]" />
                    {{ t('chat.status.online') }}
                  </span>
                </div>
                <p class="mt-1 text-xs leading-relaxed text-muted-foreground">
                  {{ t('account.appearance.previewSampleMsg') }}
                </p>
              </div>
            </div>
            <div class="bento-tile mt-2.5 px-3 py-2 text-[11px] text-muted-foreground">
              {{ t('account.appearance.glassDescription') }}
            </div>
            <div class="mt-3 flex justify-end">
              <span class="inline-flex items-center rounded-full bg-primary px-3.5 py-1 text-xs font-semibold text-primary-foreground">
                {{ t('account.header.follow') }}
              </span>
            </div>
          </div>

          <!-- Floating Liquid Glass dock preview -->
          <div class="liquid-glass-dock absolute inset-x-3 bottom-2.5 flex h-[44px] items-center rounded-full p-1">
            <div class="grid h-full w-full grid-cols-3 items-center gap-0.5">
              <div class="liquid-glass-active-pill flex h-full flex-col items-center justify-center gap-0.5 rounded-full px-1 text-primary">
                <Home class="size-3.5" :stroke-width="2.15" />
                <span class="max-w-full truncate text-[9px] font-semibold leading-none">{{ t('nav.main.home') }}</span>
              </div>
              <div class="flex h-full flex-col items-center justify-center gap-0.5 rounded-full px-1 text-muted-foreground">
                <Users class="size-3.5" :stroke-width="1.75" />
                <span class="max-w-full truncate text-[9px] leading-none">{{ t('nav.main.groups') }}</span>
              </div>
              <div class="flex h-full flex-col items-center justify-center gap-0.5 rounded-full px-1 text-muted-foreground">
                <MessageCircle class="size-3.5" :stroke-width="1.75" />
                <span class="max-w-full truncate text-[9px] leading-none">{{ t('nav.main.chat') }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section class="grid gap-4 lg:grid-cols-2">
      <article class="bento-card grid gap-4 p-5">
        <header class="flex items-center gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-secondary text-foreground"
          >
            <Palette class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.appearance.theme') }}
            </h3>
            <p class="text-xs text-muted-foreground">
              {{ t('account.appearance.description') }}
            </p>
          </div>
        </header>
        <div class="flex flex-wrap gap-2">
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="theme === 'light' ? 'default' : 'secondary'"
            @click="theme = 'light'"
          >
            {{ t('account.appearance.themeLight') }}
          </Button>
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="theme === 'dark' ? 'default' : 'secondary'"
            @click="theme = 'dark'"
          >
            {{ t('account.appearance.themeDark') }}
          </Button>
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="theme === 'system' ? 'default' : 'secondary'"
            @click="theme = 'system'"
          >
            {{ t('account.appearance.themeSystem') }}
          </Button>
        </div>
      </article>

      <article class="bento-card grid gap-4 p-5">
        <header class="flex items-center gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-secondary text-foreground"
          >
            <Sparkles class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.appearance.glass') }}
            </h3>
            <p class="text-xs text-muted-foreground">
              {{ t('account.appearance.glassDescription') }}
            </p>
          </div>
        </header>
        <div class="flex flex-wrap gap-2">
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="glassIntensity === 'standard' ? 'default' : 'secondary'"
            @click="glassIntensity = 'standard'"
          >
            {{ t('account.appearance.glassStandard') }}
          </Button>
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="glassIntensity === 'subtle' ? 'default' : 'secondary'"
            @click="glassIntensity = 'subtle'"
          >
            {{ t('account.appearance.glassSubtle') }}
          </Button>
        </div>
      </article>

      <article class="bento-card grid gap-4 p-5">
        <header class="flex items-center gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-secondary text-foreground"
          >
            <Languages class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.appearance.language') }}
            </h3>
          </div>
        </header>
        <div class="flex flex-wrap gap-2">
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="lang === 'zh' ? 'default' : 'secondary'"
            @click="lang = 'zh'"
          >
            {{ t('preferences.language.zh') }}
          </Button>
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="lang === 'en' ? 'default' : 'secondary'"
            @click="lang = 'en'"
          >
            {{ t('preferences.language.en') }}
          </Button>
        </div>
      </article>

      <article class="bento-card grid gap-4 p-5">
        <header class="flex items-center gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-secondary text-foreground"
          >
            <Type class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.appearance.fontSize') }}
            </h3>
          </div>
        </header>
        <div class="flex flex-wrap gap-2">
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="fontSize === 'small' ? 'default' : 'secondary'"
            @click="fontSize = 'small'"
          >
            {{ t('account.appearance.fontSmall') }}
          </Button>
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="fontSize === 'normal' ? 'default' : 'secondary'"
            @click="fontSize = 'normal'"
          >
            {{ t('account.appearance.fontNormal') }}
          </Button>
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="fontSize === 'large' ? 'default' : 'secondary'"
            @click="fontSize = 'large'"
          >
            {{ t('account.appearance.fontLarge') }}
          </Button>
        </div>
      </article>

      <article class="bento-card grid gap-4 p-5 lg:col-span-2">
        <header class="flex items-center gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-secondary text-foreground"
          >
            <LayoutGrid class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.appearance.compactMode') }}
            </h3>
          </div>
        </header>
        <div class="flex flex-wrap gap-2">
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="compact ? 'default' : 'secondary'"
            @click="compact = true"
          >
            {{ t('account.appearance.compactOn') }}
          </Button>
          <Button
            class="pressable h-9 rounded-full border-0 font-semibold"
            :variant="!compact ? 'default' : 'secondary'"
            @click="compact = false"
          >
            {{ t('account.appearance.compactOff') }}
          </Button>
        </div>
      </article>
    </section>
  </div>
</template>
