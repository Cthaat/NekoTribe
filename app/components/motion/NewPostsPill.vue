<script setup lang="ts">
import { computed } from 'vue';
import { ArrowUp } from 'lucide-vue-next';
import LiquidGlassSurface from '@/components/glass/LiquidGlassSurface.vue';

const props = withDefaults(
  defineProps<{
    visible: boolean;
    count?: number;
    label?: string;
  }>(),
  {
    count: 0,
    label: undefined
  }
);

const emit = defineEmits<{
  (e: 'click'): void;
}>();

const { t } = useAppLocale();

const displayText = computed(() => {
  if (props.label) return props.label;
  if (props.count > 0) return t('motion.newPostsCount', { count: props.count });
  return t('motion.backToTop');
});
</script>

<template>
  <Transition name="pill-spring">
    <div
      v-if="visible"
      class="pointer-events-none fixed inset-x-0 top-[68px] z-30 flex justify-center md:top-4 md:pl-[72px] lg:pl-[220px]"
    >
      <LiquidGlassSurface
        as="button"
        type="button"
        preset="island"
        interactive
        class="pointer-events-auto inline-flex items-center gap-1.5 rounded-full px-4 py-2 text-xs font-semibold text-primary"
        @click="emit('click')"
      >
        <ArrowUp class="size-3.5 shrink-0" />
        <span>{{ displayText }}</span>
      </LiquidGlassSurface>
    </div>
  </Transition>
</template>
