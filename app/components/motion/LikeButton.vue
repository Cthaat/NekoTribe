<script setup lang="ts">
import { ref, watch } from 'vue';
import { Heart } from 'lucide-vue-next';
import AnimatedNumber from '@/components/motion/AnimatedNumber.vue';

const { t } = useAppLocale();

const props = withDefaults(
  defineProps<{
    liked: boolean;
    count: number;
    hideCount?: boolean;
    hideZero?: boolean;
    iconClass?: string;
    disabled?: boolean;
  }>(),
  {
    hideZero: true
  }
);

const emit = defineEmits<{
  toggle: [];
}>();

const nudging = ref(false);
let nudgeTimer: ReturnType<typeof setTimeout> | null = null;

watch(
  () => props.liked,
  (next, prev) => {
    if (next && !prev) {
      nudging.value = true;
      if (nudgeTimer) clearTimeout(nudgeTimer);
      nudgeTimer = setTimeout(() => {
        nudging.value = false;
      }, 240);
    } else if (!next) {
      nudging.value = false;
    }
  }
);
</script>

<template>
  <button
    type="button"
    :disabled="props.disabled"
    class="group/like pressable inline-flex items-center rounded-full text-[13px] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50"
    :class="[
      props.hideCount ? 'gap-0 p-0.5' : 'gap-1 py-1 pr-2',
      props.liked ? 'text-[var(--like)] font-semibold' : 'text-muted-foreground hover:text-[var(--like)]'
    ]"
    :aria-label="t('post.detail.likesLabel')"
    :aria-pressed="props.liked"
    @click.stop="emit('toggle')"
  >
    <span class="relative inline-flex size-8 items-center justify-center rounded-full transition-colors group-hover/like:bg-[var(--like)]/10">
      <Heart
        :class="[
          props.iconClass ?? 'size-[18px]',
          'transition-transform duration-200',
          {
            'fill-[var(--like)] text-[var(--like)]': props.liked,
            'animate-heart-nudge': nudging
          }
        ]"
        :stroke-width="props.liked ? 2 : 1.75"
      />
    </span>
    <AnimatedNumber v-if="!props.hideCount" :value="props.count" :hide-zero="props.hideZero" />
  </button>
</template>
