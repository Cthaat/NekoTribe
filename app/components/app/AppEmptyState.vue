<script setup lang="ts">
import { computed, type Component, type HTMLAttributes } from 'vue';
import { Inbox } from 'lucide-vue-next';
import { Card, CardContent } from '@/components/ui/card';

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
  <Card
    :class="[
      'mx-auto max-w-md gap-0 border-dashed bg-muted/20 py-0',
      props.class
    ]"
  >
    <CardContent
      class="flex flex-col items-center justify-center px-6 py-10 text-center"
    >
      <component
        :is="emptyIcon"
        class="mb-3 h-9 w-9 text-muted-foreground"
        aria-hidden="true"
      />
      <h3 class="text-sm font-medium">
        {{ props.title }}
      </h3>
      <p
        v-if="props.description"
        class="mt-1 text-sm text-muted-foreground"
      >
        {{ props.description }}
      </p>
      <div v-if="$slots.default" class="mt-4">
        <slot />
      </div>
    </CardContent>
  </Card>
</template>
