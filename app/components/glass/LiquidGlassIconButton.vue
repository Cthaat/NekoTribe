<script setup lang="ts">
withDefaults(
  defineProps<{
    type?: 'button' | 'submit' | 'reset';
    disabled?: boolean;
    ariaLabel?: string;
    title?: string;
  }>(),
  {
    type: 'button',
    disabled: false,
    ariaLabel: undefined,
    title: undefined
  }
);
</script>

<template>
  <button
    :type="type"
    :disabled="disabled"
    :aria-label="ariaLabel"
    :title="title"
    class="rounded-full liquid-glass-button pressable inline-flex size-9 shrink-0 items-center justify-center text-muted-foreground transition-colors hover:text-foreground disabled:pointer-events-none disabled:opacity-50"
  >
    <slot />
  </button>
</template>
