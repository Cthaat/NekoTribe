<script setup lang="ts">
import { computed } from 'vue';
import { useScrollDirection } from '@/composables/useScrollDirection';

const { t } = useAppLocale();
const { progress, maxScroll } = useScrollDirection();

const visible = computed(() => maxScroll.value > 220 && progress.value > 0.01);
const barStyle = computed(() => ({
  transform: `scaleX(${Math.min(1, Math.max(0, progress.value)).toFixed(4)})`
}));
</script>

<template>
  <div
    v-show="visible"
    class="pointer-events-none fixed inset-x-0 top-0 z-50 h-[2px] overflow-hidden bg-transparent"
    role="progressbar"
    aria-valuemin="0"
    aria-valuemax="100"
    :aria-valuenow="Math.round(progress * 100)"
    :aria-label="t('motion.readingProgress')"
  >
    <div
      class="h-full w-full origin-left bg-primary/85 transition-transform duration-75 will-change-transform"
      :style="barStyle"
    />
  </div>
</template>
