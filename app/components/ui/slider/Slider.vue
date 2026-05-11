<script setup lang="ts">
import type { HTMLAttributes } from 'vue'
import { reactiveOmit } from '@vueuse/core'
import {
  SliderRange,
  SliderRoot,
  type SliderRootEmits,
  type SliderRootProps,
  SliderThumb,
  SliderTrack,
  useForwardPropsEmits,
} from 'reka-ui'
import { cn } from '@/lib/utils'

const props = defineProps<SliderRootProps & {
  class?: HTMLAttributes['class']
}>()
const emits = defineEmits<SliderRootEmits>()

const delegatedProps = reactiveOmit(props, 'class')
const forwarded = useForwardPropsEmits(delegatedProps, emits)
</script>

<template>
  <SliderRoot
    data-slot="slider"
    v-bind="forwarded"
    :class="cn(
      'relative flex w-full touch-none select-none items-center data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50',
      props.class,
    )"
  >
    <SliderTrack
      data-slot="slider-track"
      class="bg-muted relative h-1.5 w-full grow overflow-hidden rounded-full"
    >
      <SliderRange
        data-slot="slider-range"
        class="bg-primary absolute h-full"
      />
    </SliderTrack>
    <SliderThumb
      data-slot="slider-thumb"
      class="border-primary bg-background ring-ring/50 block size-4 rounded-full border shadow-sm transition-[color,box-shadow] hover:ring-4 focus-visible:ring-4 focus-visible:outline-none disabled:pointer-events-none disabled:opacity-50"
    />
  </SliderRoot>
</template>
