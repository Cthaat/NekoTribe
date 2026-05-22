<script setup lang="ts">
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader
} from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
</script>

<template>
  <Card
    class="mx-auto my-3 max-w-2xl overflow-hidden rounded-xl border border-border/60 bg-card py-0 shadow-none"
  >
    <CardHeader class="flex flex-row items-start gap-3 px-5 pb-2 pt-5 sm:gap-4">
      <Skeleton class="h-10 w-10 shrink-0 rounded-full sm:h-11 sm:w-11" />
      <div class="flex-1 space-y-2 pt-1">
        <Skeleton class="h-3.5 w-40" />
        <Skeleton class="h-3 w-28" />
      </div>
      <Skeleton class="h-8 w-8 shrink-0 rounded-full" />
    </CardHeader>

    <CardContent class="space-y-3 px-5 pb-3">
      <div class="space-y-2">
        <Skeleton class="h-4 w-full" />
        <Skeleton class="h-4 w-[88%]" />
        <Skeleton class="h-4 w-[60%]" />
      </div>

      <Skeleton class="h-64 w-full rounded-xl" />
    </CardContent>

    <CardFooter class="flex items-center justify-between gap-1 border-t border-border/40 bg-muted/20 px-2 py-2">
      <Skeleton class="h-7 flex-1 rounded-md" />
      <Skeleton class="h-7 flex-1 rounded-md" />
      <Skeleton class="h-7 flex-1 rounded-md" />
    </CardFooter>
  </Card>
</template>
