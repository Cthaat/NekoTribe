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
      'peer data-[state=checked]:bg-primary data-[state=unchecked]:bg-input focus-visible:border-ring focus-visible:ring-ring/50 dark:data-[state=unchecked]:bg-input inline-flex h-[28px] w-[48px] shrink-0 items-center rounded-full border-0 p-[2px] transition-colors outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50',
      props.class,
    )"
  >
    <SwitchThumb
      data-slot="switch-thumb"
      :class="cn('pointer-events-none block size-[24px] rounded-full bg-white shadow-[0_2px_6px_rgba(15,23,42,0.18)] ring-0 transition-transform duration-200 ease-[var(--ease-spring)] data-[state=checked]:translate-x-[20px] data-[state=unchecked]:translate-x-0')"
    >
      <slot name="thumb" />
    </SwitchThumb>
  </SwitchRoot>
</template>
