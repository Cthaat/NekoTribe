<script setup lang="ts">
import { Loader2 } from 'lucide-vue-next';

defineProps<{
  text?: string;
  variant?: 'overlay' | 'inline';
}>();

const { t } = useAppLocale();
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center bg-background/70 backdrop-blur-md transition-opacity"
    role="status"
    aria-live="polite"
  >
    <div
      class="flex flex-col items-center gap-3 rounded-2xl border border-border/60 bg-card/95 px-8 py-6 shadow-xl"
    >
      <Loader2 class="h-7 w-7 animate-spin text-primary" />
      <p class="text-sm font-medium text-foreground">
        {{ text || t('common.processing') }}
      </p>
    </div>
  </div>
</template>
