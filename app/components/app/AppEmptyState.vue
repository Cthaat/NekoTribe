<script setup lang="ts">
import type { Component, HTMLAttributes } from 'vue';

interface Props {
  title: string;
  description?: string;
  icon?: Component;
  class?: HTMLAttributes['class'];
}

const props = defineProps<Props>();
</script>

<template>
  <div
    :class="[
      'mx-auto flex max-w-md flex-col items-center justify-center rounded-[20px] bg-card/70 px-6 py-12 text-center shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none',
      props.class
    ]"
  >
    <div
      class="mb-4 flex h-[76px] w-[76px] items-center justify-center rounded-full bg-secondary/80"
      aria-hidden="true"
    >
      <component
        :is="props.icon"
        v-if="props.icon"
        class="h-6 w-6 text-muted-foreground"
      />
      <svg
        v-else
        viewBox="0 0 64 64"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="h-12 w-12 text-[var(--ink-tertiary)]"
      >
        <path
          d="M15 28L17 13L25 21C29.5 19.5 34.5 19.5 39 21L47 13L49 28C53 35.5 50.5 47.5 41.5 50.5C35.5 52.8 28.5 52.8 22.5 50.5C13.5 47.5 11 35.5 15 28Z"
        />
        <path d="M23 34.5Q25.5 32.5 28 34.5" />
        <path d="M36 34.5Q38.5 32.5 41 34.5" />
        <path d="M30.5 39H33.5" />
        <path d="M10 37L17.5 37.8" />
        <path d="M11 41.5L17.5 41" />
        <path d="M54 37L46.5 37.8" />
        <path d="M53 41.5L46.5 41" />
      </svg>
    </div>
    <h3 class="text-[15px] font-semibold tracking-tight text-foreground">
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
