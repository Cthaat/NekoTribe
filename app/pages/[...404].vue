<script setup lang="ts">
// 无页面布局
definePageMeta({
  layout: false
});
import { AlertTriangle, Home } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle
} from '@/components/ui/card';

const { t } = useAppLocale();

// Nuxt 会自动将错误信息作为 props 传入
defineProps({
  error: Object
});

// 处理返回首页的事件
const handleClearError = () =>
  clearError({ redirect: '/' });
</script>

<template>
  <div
    class="flex min-h-screen items-center justify-center bg-background p-4"
  >
    <Card class="w-full max-w-md text-center shadow-lg">
      <CardHeader>
        <div
          class="mx-auto mb-4 flex size-16 items-center justify-center rounded-full bg-destructive/10"
        >
          <AlertTriangle class="size-10 text-destructive" />
        </div>
        <CardTitle
          class="text-3xl font-bold tracking-tight"
        >
          {{ t('errorPage.notFound.title') }}
        </CardTitle>
        <CardDescription
          class="text-lg text-muted-foreground"
        >
          {{ t('errorPage.notFound.description') }}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <div
          class="space-y-2 text-left text-sm text-muted-foreground"
        >
          <p>{{ t('errorPage.notFound.possibleReasons') }}</p>
          <ul class="list-inside list-disc space-y-1">
            <li>{{ t('errorPage.notFound.invalidUrl') }}</li>
            <li>
              {{ t('errorPage.notFound.movedOrDeleted') }}
            </li>
            <li>{{ t('errorPage.notFound.serverBusy') }}</li>
          </ul>
        </div>
      </CardContent>
      <CardFooter>
        <Button class="w-full" @click="handleClearError">
          <Home class="mr-2 size-4" />
          {{ t('errorPage.notFound.backHome') }}
        </Button>
      </CardFooter>
    </Card>
  </div>
</template>
