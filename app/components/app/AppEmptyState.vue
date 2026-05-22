<script setup lang="ts">
import { computed, type Component, type HTMLAttributes } from 'vue';
import { Inbox } from 'lucide-vue-next';

interface Props {
  title: string;
  description?: string;
  icon?: Component;
  class?: HTMLAttributes['class'];
}

const props = defineProps<Props>();
const emptyIcon = computed(() => props.icon ?? Inbox);
</script>

<template>
  <div
    :class="[
      'mx-auto flex max-w-md flex-col items-center justify-center rounded-xl border border-dashed border-border/60 bg-muted/10 px-6 py-12 text-center',
      props.class
    ]"
  >
    <div
      class="mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
    >
      <component
        :is="emptyIcon"
        class="h-5 w-5 text-muted-foreground"
        aria-hidden="true"
      />
    </div>
    <h3 class="text-base font-semibold tracking-tight">
      {{ props.title }}
    </h3>
    <p
      v-if="props.description"
      class="mt-1.5 max-w-sm text-sm leading-relaxed text-muted-foreground"
    >
      {{ props.description }}
    </p>
    <div v-if="$slots.default" class="mt-5">
      <slot />
    </div>
  </div>
</template>
