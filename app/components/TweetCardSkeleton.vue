<script setup lang="ts">
// 这个组件非常“纯粹”，它只需要导入 Card 布局组件和 Skeleton 组件
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader
} from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
</script>

<template>
  <Card class="max-w-2xl mx-auto my-4 rounded-xl shadow-sm">
    <!-- 头部骨架：模仿头像、用户名和日期 -->
    <CardHeader class="flex flex-row items-start p-4">
      <!-- 模仿 Avatar -->
      <Skeleton class="h-12 w-12 mr-4 rounded-full" />

      <!-- 模仿用户名和日期信息 -->
      <div class="flex-1 space-y-2">
        <Skeleton class="h-4 w-32" />
        <Skeleton class="h-3 w-48" />
      </div>

      <!-- 模仿右上角的“更多”按钮 -->
      <Skeleton class="h-8 w-8 rounded-md" />
    </CardHeader>

    <!-- 内容骨架：模仿推文正文和可能的媒体图片 -->
    <CardContent class="px-4 pb-2">
      <!-- 模仿推文文字，多行且长度不一，看起来更真实 -->
      <div class="space-y-2">
        <Skeleton class="h-4 w-full" />
        <Skeleton class="h-4 w-[90%]" />
      </div>

      <!-- 模仿媒体展示区 (一张大图) -->
      <!-- 如果你的卡片不一定有图片，可以把这块骨架的高度减小或去掉 -->
      <Skeleton class="mt-3 h-64 rounded-lg" />
    </CardContent>

    <!-- 底部骨架：模仿三个交互按钮 -->
    <CardFooter class="flex justify-around p-2">
      <Skeleton class="h-8 w-20 rounded-md" />
      <Skeleton class="h-8 w-20 rounded-md" />
      <Skeleton class="h-8 w-20 rounded-md" />
    </CardFooter>
  </Card>
</template>
