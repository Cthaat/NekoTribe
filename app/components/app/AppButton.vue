<script setup lang="ts">
import type { HTMLAttributes } from 'vue';
import { Loader2 } from 'lucide-vue-next';
import { Button, type ButtonVariants } from '@/components/ui/button';

interface Props {
  variant?: ButtonVariants['variant'];
  size?: ButtonVariants['size'];
  loading?: boolean;
  loadingLabel?: string;
  disabled?: boolean;
  class?: HTMLAttributes['class'];
}

const props = withDefaults(defineProps<Props>(), {
  loading: false,
  disabled: false,
  variant: 'default',
  size: 'default'
});
</script>

<template>
  <Button
    :variant="props.variant"
    :size="props.size"
    :class="props.class"
    :disabled="props.disabled || props.loading"
    v-bind="$attrs"
  >
    <Loader2
      v-if="props.loading"
      class="h-4 w-4 animate-spin"
      aria-hidden="true"
    />
    <span>
      <slot>
        {{ props.loading ? props.loadingLabel : '' }}
      </slot>
    </span>
  </Button>
</template>
