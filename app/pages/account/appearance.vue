<script setup lang="ts">
import { computed } from 'vue';
import {
  Languages,
  LayoutGrid,
  Palette,
  Type
} from 'lucide-vue-next';
import { usePreferenceStore } from '@/stores/user';
import type { LanguageCode } from '@/stores/type';
import { Button } from '@/components/ui/button';

const pref = usePreferenceStore();
const { locale, t, setAppLocale } = useAppLocale();

const theme = computed({
  get: () => pref.preferences.theme_mode,
  set: v => pref.updatePreference('theme_mode', v)
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
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
        >
          <Palette class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('account.appearance.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.appearance.description') }}
          </p>
        </div>
      </header>
    </section>

    <section class="grid gap-4 lg:grid-cols-2">
      <article
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
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
            class="h-9 rounded-md shadow-xs"
            :variant="theme === 'light' ? 'default' : 'outline'"
            @click="theme = 'light'"
          >
            {{ t('account.appearance.themeLight') }}
          </Button>
          <Button
            class="h-9 rounded-md shadow-xs"
            :variant="theme === 'dark' ? 'default' : 'outline'"
            @click="theme = 'dark'"
          >
            {{ t('account.appearance.themeDark') }}
          </Button>
          <Button
            class="h-9 rounded-md shadow-xs"
            :variant="theme === 'system' ? 'default' : 'outline'"
            @click="theme = 'system'"
          >
            {{ t('account.appearance.themeSystem') }}
          </Button>
        </div>
      </article>

      <article
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
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
            class="h-9 rounded-md shadow-xs"
            :variant="lang === 'zh' ? 'default' : 'outline'"
            @click="lang = 'zh'"
          >
            {{ t('preferences.language.zh') }}
          </Button>
          <Button
            class="h-9 rounded-md shadow-xs"
            :variant="lang === 'en' ? 'default' : 'outline'"
            @click="lang = 'en'"
          >
            {{ t('preferences.language.en') }}
          </Button>
        </div>
      </article>

      <article
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
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
            class="h-9 rounded-md shadow-xs"
            :variant="fontSize === 'small' ? 'default' : 'outline'"
            @click="fontSize = 'small'"
          >
            {{ t('account.appearance.fontSmall') }}
          </Button>
          <Button
            class="h-9 rounded-md shadow-xs"
            :variant="fontSize === 'normal' ? 'default' : 'outline'"
            @click="fontSize = 'normal'"
          >
            {{ t('account.appearance.fontNormal') }}
          </Button>
          <Button
            class="h-9 rounded-md shadow-xs"
            :variant="fontSize === 'large' ? 'default' : 'outline'"
            @click="fontSize = 'large'"
          >
            {{ t('account.appearance.fontLarge') }}
          </Button>
        </div>
      </article>

      <article
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
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
            class="h-9 rounded-md shadow-xs"
            :variant="compact ? 'default' : 'outline'"
            @click="compact = true"
          >
            {{ t('account.appearance.compactOn') }}
          </Button>
          <Button
            class="h-9 rounded-md shadow-xs"
            :variant="!compact ? 'default' : 'outline'"
            @click="compact = false"
          >
            {{ t('account.appearance.compactOff') }}
          </Button>
        </div>
      </article>
    </section>
  </div>
</template>
