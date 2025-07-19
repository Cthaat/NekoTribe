<script setup lang="ts">
// 1. 导入 Separator 和 Button (如果它们还没被自动导入)
import { Separator } from '@/components/ui/separator';
import { Button } from '@/components/ui/button';

// 2. 导入我们功能强大的推文编辑器组件
import TweetComposer from '@/components/TweetComposer.vue';
</script>

<template>
  <!-- 
    我们将移除外层的 `hidden md:block`，让页面在所有设备上都可见。
    并调整一些间距，让布局更和谐。
  -->
  <div class="space-y-6 p-4 sm:p-8">
    <div
      class="flex items-center justify-between padding-bottom-4 px-3"
    >
      <div>
        <h2 class="text-2xl font-bold tracking-tight">
          发布推文
        </h2>
        <p class="text-muted-foreground text-sm mt-1">
          分享你的想法，与世界连接。
        </p>
      </div>
      <!-- 这个按钮可以链接到草稿箱或执行其他操作 -->
      <Button variant="secondary">查看草稿</Button>
    </div>

    <!-- 分割线 -->
    <Separator class="my-6" />

    <!-- 
      3. 【核心修改】在分割线下方，直接放置我们的推文编辑器组件。
         我们将移除编辑器内部的 Card 样式，让它直接融入当前页面。
         为此，我们需要给它传递一个 prop。
    -->
    <div class="mx-auto max-w-3xl">
      <!-- 
         为了让 TweetComposer 更好地融入页面，
         我们可以给它传递一个 prop 来控制是否显示 Card 样式。
         这需要对 TweetComposer 做一个小小的修改。
       -->
      <TweetComposer />
    </div>
  </div>
</template>
