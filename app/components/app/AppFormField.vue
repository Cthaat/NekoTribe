<script setup lang="ts">
import {
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage
} from '@/components/ui/form';

interface Props {
  name: string;
  label?: string;
  description?: string;
}

const props = defineProps<Props>();
</script>

<template>
  <FormField v-slot="slotProps" :name="props.name">
    <FormItem>
      <FormLabel v-if="props.label">
        {{ props.label }}
      </FormLabel>
      <FormControl>
        <slot v-bind="slotProps" />
      </FormControl>
      <FormDescription v-if="props.description">
        {{ props.description }}
      </FormDescription>
      <FormMessage />
    </FormItem>
  </FormField>
</template>
