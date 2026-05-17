<script setup lang="ts">
import type { HTMLAttributes } from 'vue'
import { reactiveOmit } from '@vueuse/core'
import { computed } from 'vue'
import {
  SwitchRoot,
  type SwitchRootEmits,
  type SwitchRootProps,
  SwitchThumb,
} from 'reka-ui'
import { cn } from '@/lib/utils'

type SwitchProps = SwitchRootProps & {
  checked?: boolean | null
  class?: HTMLAttributes['class']
}

type SwitchEmits = SwitchRootEmits & {
  'update:checked': [payload: boolean]
}

const props = defineProps<SwitchProps>()

const emits = defineEmits<SwitchEmits>()

const delegatedProps = reactiveOmit(
  props,
  'checked',
  'class',
  'modelValue'
)

const modelValue = computed({
  get: () => props.checked ?? props.modelValue,
  set: (value: boolean) => {
    emits('update:modelValue', value)
    emits('update:checked', value)
  },
})

</script>

<template>
  <SwitchRoot
    data-slot="switch"
    v-bind="delegatedProps"
    v-model="modelValue"
    :class="cn(
      'peer data-[state=checked]:bg-primary data-[state=unchecked]:bg-input focus-visible:border-ring focus-visible:ring-ring/50 dark:data-[state=unchecked]:bg-input/80 inline-flex h-[1.15rem] w-8 shrink-0 items-center rounded-full border border-transparent shadow-xs transition-all outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50',
      props.class,
    )"
  >
    <SwitchThumb
      data-slot="switch-thumb"
      :class="cn('bg-background dark:data-[state=unchecked]:bg-foreground dark:data-[state=checked]:bg-primary-foreground pointer-events-none block size-4 rounded-full ring-0 transition-transform data-[state=checked]:translate-x-[calc(100%-2px)] data-[state=unchecked]:translate-x-0')"
    >
      <slot name="thumb" />
    </SwitchThumb>
  </SwitchRoot>
</template>
