<script setup lang="ts">
import { Construction } from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';

const { t } = useAppLocale();
</script>

<template>
  <Card class="border-dashed">
    <CardHeader class="text-center">
      <div
        class="mx-auto p-4 bg-muted rounded-full w-fit mb-4"
      >
        <Construction
          class="h-8 w-8 text-muted-foreground"
        />
      </div>
      <CardTitle>{{
        t('moderation.placeholder.reports.title')
      }}</CardTitle>
      <CardDescription>
        {{ t('moderation.placeholder.description') }}
      </CardDescription>
    </CardHeader>
    <CardContent
      class="text-center text-sm text-muted-foreground"
    >
      <p>{{ t('moderation.placeholder.reports.intro') }}</p>
      <ul class="mt-2 space-y-1">
        <li>• {{ t('moderation.placeholder.reports.item1') }}</li>
        <li>• {{ t('moderation.placeholder.reports.item2') }}</li>
        <li>• {{ t('moderation.placeholder.reports.item3') }}</li>
        <li>• {{ t('moderation.placeholder.reports.item4') }}</li>
      </ul>
    </CardContent>
  </Card>
</template>
