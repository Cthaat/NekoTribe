<script setup lang="ts">
import { Construction } from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
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
      <CardTitle>审核设置</CardTitle>
      <CardDescription>
        此功能正在开发中，敬请期待...
      </CardDescription>
    </CardHeader>
    <CardContent
      class="text-center text-sm text-muted-foreground"
    >
      <p>审核设置功能将包括：</p>
      <ul class="mt-2 space-y-1">
        <li>• 自动审核规则配置</li>
        <li>• 敏感词库管理</li>
        <li>• 审核流程设置</li>
        <li>• 通知偏好设置</li>
      </ul>
    </CardContent>
  </Card>
</template>
