<script setup lang="ts">
import type { HTMLAttributes } from 'vue';
import { Loader2, Send } from 'lucide-vue-next';
import { Button, type ButtonVariants } from '@/components/ui/button';
import { cn } from '@/lib/utils';

defineOptions({
  inheritAttrs: false
});

interface Props {
  variant?: ButtonVariants['variant'];
  size?: ButtonVariants['size'];
  loading?: boolean;
  disabled?: boolean;
  iconOnly?: boolean;
  ariaLabel?: string;
  class?: HTMLAttributes['class'];
}

const props = withDefaults(defineProps<Props>(), {
  variant: 'default',
  size: 'default',
  loading: false,
  disabled: false,
  iconOnly: false,
  ariaLabel: 'Send'
});
</script>

<template>
  <Button
    v-bind="$attrs"
    :variant="props.variant"
    :size="props.iconOnly ? 'icon' : props.size"
    :disabled="props.disabled || props.loading"
    :aria-label="props.iconOnly ? props.ariaLabel : undefined"
    :class="
      cn(
        'shadow-sm disabled:opacity-100 disabled:bg-muted/60 disabled:text-muted-foreground',
        'focus-visible:ring-ring/50 focus-visible:ring-[3px]',
        props.iconOnly
          ? 'size-11 rounded-lg disabled:border disabled:border-border'
          : 'rounded-md font-medium',
        props.class
      )
    "
  >
    <Loader2
      v-if="props.loading"
      class="size-4 animate-spin"
      aria-hidden="true"
    />
    <Send
      v-else
      class="size-4 translate-x-px"
      aria-hidden="true"
    />
    <span v-if="!props.iconOnly">
      <slot />
    </span>
  </Button>
</template>
