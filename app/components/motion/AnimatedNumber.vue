<script setup lang="ts">
import { ref, watch } from 'vue';

const props = withDefaults(
  defineProps<{
    value: number;
    hideZero?: boolean;
  }>(),
  { hideZero: false }
);

const direction = ref<'count-up' | 'count-down'>('count-up');

watch(
  () => props.value,
  (next, prev) => {
    direction.value = next >= prev ? 'count-up' : 'count-down';
  }
);
</script>

<template>
  <span
    v-if="!(props.hideZero && props.value <= 0)"
    class="relative inline-flex min-w-[1ch] items-center overflow-hidden tabular-nums"
  >
    <Transition :name="direction" mode="out-in">
      <span :key="props.value" class="inline-block leading-none">
        {{ props.value }}
      </span>
    </Transition>
  </span>
</template>
