<script setup lang="ts">
import { computed } from 'vue';

const props = withDefaults(
  defineProps<{
    index: number;
    maxItems?: number;
  }>(),
  {
    maxItems: 8
  }
);

const eligible = computed(() => props.index >= 0 && props.index < props.maxItems);
const itemStyle = computed(() =>
  eligible.value ? { '--stagger-index': String(props.index) } : undefined
);
</script>

<template>
  <div :class="eligible ? 'stagger-item' : undefined" :style="itemStyle">
    <slot />
  </div>
</template>
