<script setup lang="ts">
definePageMeta({
  layout: false
});
import { AlertTriangle, Home } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';

const { t } = useAppLocale();

defineProps({
  error: Object
});

const handleClearError = () =>
  clearError({ redirect: '/' });
</script>

<template>
  <div
    class="flex min-h-screen items-center justify-center bg-background p-4"
  >
    <div
      class="grid w-full max-w-md gap-5 rounded-xl border border-border/60 bg-card p-6 text-center shadow-none sm:p-8"
    >
      <div
        class="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-rose-500/10 ring-1 ring-rose-500/20"
      >
        <AlertTriangle class="h-6 w-6 text-rose-500" />
      </div>

      <div class="grid gap-1.5">
        <h1
          class="text-2xl font-semibold tracking-tight sm:text-3xl"
        >
          {{ t('errorPage.notFound.title') }}
        </h1>
        <p class="text-sm text-muted-foreground">
          {{ t('errorPage.notFound.description') }}
        </p>
      </div>

      <div
        class="grid gap-2 rounded-lg border border-border/60 bg-muted/20 p-4 text-left"
      >
        <p class="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
          {{ t('errorPage.notFound.possibleReasons') }}
        </p>
        <ul class="grid gap-1.5 text-xs text-muted-foreground">
          <li class="flex items-start gap-2">
            <span class="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-muted-foreground/60" />
            {{ t('errorPage.notFound.invalidUrl') }}
          </li>
          <li class="flex items-start gap-2">
            <span class="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-muted-foreground/60" />
            {{ t('errorPage.notFound.movedOrDeleted') }}
          </li>
          <li class="flex items-start gap-2">
            <span class="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-muted-foreground/60" />
            {{ t('errorPage.notFound.serverBusy') }}
          </li>
        </ul>
      </div>

      <Button
        class="h-9 w-full rounded-md shadow-xs"
        @click="handleClearError"
      >
        <Home class="h-3.5 w-3.5" />
        {{ t('errorPage.notFound.backHome') }}
      </Button>
    </div>
  </div>
</template>
