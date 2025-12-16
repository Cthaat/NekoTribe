<script setup lang="ts">
import { Construction } from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';

definePageMeta({
  layout: false
});
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
      <CardTitle>用户管理</CardTitle>
      <CardDescription>
        此功能正在开发中，敬请期待...
      </CardDescription>
    </CardHeader>
    <CardContent
      class="text-center text-sm text-muted-foreground"
    >
      <p>用户管理功能将包括：</p>
      <ul class="mt-2 space-y-1">
        <li>• 用户列表查看与搜索</li>
        <li>• 用户封禁与解封</li>
        <li>• 用户角色管理</li>
        <li>• 用户行为日志查看</li>
      </ul>
    </CardContent>
  </Card>
</template>
