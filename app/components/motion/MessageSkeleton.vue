<script setup lang="ts">
import { Skeleton } from '@/components/ui/skeleton';
</script>

<template>
  <div class="space-y-4 p-4" aria-busy="true">
    <div v-for="n in 3" :key="n" class="flex items-end gap-2" :class="{ 'flex-row-reverse': n === 2 }">
      <Skeleton class="size-8 shrink-0 rounded-full" />
      <div class="w-3/5 space-y-2 rounded-2xl bg-secondary p-3">
        <Skeleton class="h-3 w-16" /><Skeleton class="h-3 w-4/5" />
      </div>
    </div>
  </div>
</template>
