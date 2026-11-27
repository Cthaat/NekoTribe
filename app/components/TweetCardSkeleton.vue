<script setup lang="ts">
import { Skeleton } from '@/components/ui/skeleton';
</script>

<template>
  <div
    class="bento-card px-4 pt-4 pb-3"
  >
    <div class="flex items-start gap-3">
      <Skeleton class="size-10 shrink-0 rounded-full" />
      <div class="min-w-0 flex-1 space-y-2.5">
        <div class="flex items-center gap-2">
          <Skeleton class="h-3.5 w-24 rounded-md" />
          <Skeleton class="h-3 w-16 rounded-md" />
        </div>
        <div class="space-y-2">
          <Skeleton class="h-3.5 w-full rounded-md" />
          <Skeleton class="h-3.5 w-4/5 rounded-md" />
        </div>
        <div class="flex items-center gap-5 pt-1">
          <Skeleton class="h-3.5 w-9 rounded-full" />
          <Skeleton class="h-3.5 w-9 rounded-full" />
          <Skeleton class="h-3.5 w-9 rounded-full" />
          <Skeleton class="ml-auto h-3.5 w-6 rounded-full" />
        </div>
      </div>
    </div>
  </div>
</template>
