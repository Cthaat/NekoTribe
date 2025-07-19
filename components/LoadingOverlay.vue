<script setup lang="ts">
import { LoaderCircle } from 'lucide-vue-next';

defineProps<{
  text?: string; // 允许自定义加载时显示的文字
}>();
</script>

<template>
  <!-- 
    使用 fixed 定位和 inset-0 来覆盖整个屏幕。
    z-50 确保它在最高层级。
    bg-black/70 创建一个半透明的黑色背景。
  -->
  <div
    class="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm"
  >
    <div
      class="flex flex-col items-center gap-4 text-white"
    >
      <LoaderCircle class="h-10 w-10 animate-spin" />
      <p class="text-lg font-semibold">
        {{ text || '正在处理中...' }}
      </p>
    </div>
  </div>
</template>
