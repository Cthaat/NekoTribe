<script setup lang="ts">
import { TooltipProvider as RekaTooltipProvider, type TooltipProviderProps } from 'reka-ui'

const props = withDefaults(defineProps<TooltipProviderProps>(), {
  delayDuration: 0,
})
</script>

<template>
  <RekaTooltipProvider v-bind="props">
    <slot />
  </RekaTooltipProvider>
</template>
