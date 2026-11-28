<script setup lang="ts">
import type { HTMLAttributes } from 'vue'
import { ref } from 'vue'
import { useSheetDrag } from '@/composables/useSheetDrag'
import { reactiveOmit } from '@vueuse/core'
import { X } from 'lucide-vue-next'
import {
  injectDialogRootContext,
  DialogClose,
  DialogContent,
  type DialogContentEmits,
  type DialogContentProps,
  DialogPortal,
  useForwardPropsEmits,
} from 'reka-ui'
import { cn } from '@/lib/utils'
import SheetOverlay from './SheetOverlay.vue'

interface SheetContentProps extends DialogContentProps {
  class?: HTMLAttributes['class']
  side?: 'top' | 'right' | 'bottom' | 'left'
}

defineOptions({
  inheritAttrs: false,
})

const props = withDefaults(defineProps<SheetContentProps>(), {
  side: 'right',
})
const emits = defineEmits<DialogContentEmits>()

const delegatedProps = reactiveOmit(props, 'class', 'side')

const { onOpenChange } = injectDialogRootContext()
const { t } = useAppLocale()
const handle = ref<HTMLElement>()
const drag = useSheetDrag(handle, () => onOpenChange(false))
const forwarded = useForwardPropsEmits(delegatedProps, emits)
</script>

<template>
  <DialogPortal>
    <SheetOverlay />
    <DialogContent
      data-slot="sheet-content"
      :style="{ translate: drag.offset.value ? '0 ' + drag.offset.value + 'px' : undefined }"
      :class="cn(
        'liquid-glass-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out fixed z-50 flex max-w-full flex-col gap-4 overflow-y-auto overscroll-contain border-0 glass-sheet',
        side === 'right'
          && 'data-[state=closed]:slide-out-to-right data-[state=open]:slide-in-from-right inset-y-0 right-0 h-full w-full sm:w-3/4 sm:max-w-sm sm:rounded-l-[28px]',
        side === 'left'
          && 'data-[state=closed]:slide-out-to-left data-[state=open]:slide-in-from-left inset-y-0 left-0 h-full w-full sm:w-3/4 sm:max-w-sm sm:rounded-r-[28px]',
        side === 'top'
          && 'data-[state=closed]:slide-out-to-top data-[state=open]:slide-in-from-top inset-x-0 top-0 h-auto rounded-b-[28px]',
        side === 'bottom'
          && 'data-[state=closed]:slide-out-to-bottom data-[state=open]:slide-in-from-bottom inset-x-0 bottom-0 max-h-[90dvh] h-auto rounded-t-[28px]',
        props.class)"
      v-bind="{ ...forwarded, ...$attrs }"
    >
      <div v-if="side === 'bottom'" ref="handle" aria-hidden="true"
        class="grid h-7 shrink-0 touch-none select-none place-items-center sm:hidden"
        @pointerdown="drag.start" @pointermove="drag.move" @pointerup="drag.finish"
        @pointercancel="drag.cancel" @lostpointercapture="drag.cancel">
        <span class="h-1 w-10 rounded-full bg-foreground/35" />
      </div>
      <slot />

      <DialogClose
        class="ring-offset-background focus:ring-ring data-[state=open]:bg-secondary absolute top-4 right-4 rounded-full p-1 opacity-70 transition-opacity hover:opacity-100 focus:ring-2 focus:ring-offset-2 focus:outline-hidden disabled:pointer-events-none"
      >
        <X class="size-4" />
        <span class="sr-only">{{ t('common.close') }}</span>
      </DialogClose>
    </DialogContent>
  </DialogPortal>
</template>
