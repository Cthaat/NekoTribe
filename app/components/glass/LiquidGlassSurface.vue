<script setup lang="ts">
import { computed, type Component } from 'vue';

export type LiquidGlassPreset = 'dock' | 'island' | 'popover' | 'button' | 'pill';

const props = withDefaults(
  defineProps<{
    as?: string | Component;
    preset?: LiquidGlassPreset;
    interactive?: boolean;
  }>(),
  {
    as: 'div',
    preset: 'island',
    interactive: false
  }
);

const presetClasses: Record<LiquidGlassPreset, string> = {
  dock: 'liquid-glass-dock',
  island: 'liquid-glass-island',
  popover: 'liquid-glass-popover',
  button: 'liquid-glass-button',
  pill: 'liquid-glass-active-pill'
};

const surfaceClass = computed(() => [
  presetClasses[props.preset],
  props.interactive ? 'pressable' : ''
]);
</script>

<template>
  <component :is="as" :class="surfaceClass">
    <slot />
  </component>
</template>
