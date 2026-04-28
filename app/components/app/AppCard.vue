<script setup lang="ts">
import type { HTMLAttributes } from 'vue';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';

interface Props {
  title?: string;
  description?: string;
  class?: HTMLAttributes['class'];
  contentClass?: HTMLAttributes['class'];
}

const props = defineProps<Props>();
</script>

<template>
  <Card :class="props.class">
    <CardHeader
      v-if="props.title || props.description || $slots.header"
      class="gap-1.5"
    >
      <slot name="header">
        <CardTitle v-if="props.title">
          {{ props.title }}
        </CardTitle>
        <CardDescription v-if="props.description">
          {{ props.description }}
        </CardDescription>
      </slot>
    </CardHeader>
    <CardContent :class="props.contentClass">
      <slot />
    </CardContent>
  </Card>
</template>
