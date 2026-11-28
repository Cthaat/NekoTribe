<script setup lang="ts">
import { ref, watch } from 'vue';

const props = defineProps<{ value: number; hideZero?: boolean }>();
const previous = ref(props.value);
const turn = ref(0);
watch(() => props.value, (_, old) => {
  previous.value = old;
  turn.value++;
});
</script>

<template>
  <span v-if="!hideZero || value > 0" class="odometer relative inline-block overflow-hidden align-bottom tabular-nums">
    <span class="invisible" aria-hidden="true">{{ value }}</span>
    <span class="sr-only">{{ value }}</span>
    <span :key="turn" aria-hidden="true" class="absolute inset-0" :style="{ '--roll': value >= previous ? '100%' : '-100%' }">
      <span v-if="turn && (!hideZero || previous > 0)" class="odometer-out">{{ previous }}</span>
      <span :class="{ 'odometer-in': turn }">{{ value }}</span>
    </span>
  </span>
</template>
