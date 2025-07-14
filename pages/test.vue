<template>
  <div class="flex h-screen w-full items-center justify-center gap-4">
    <Button @click="() => toast('一个普通的 Sonner 通知')">
      普通通知
    </Button>
    <Button variant="destructive" @click="() => toast.error('一个错误的 Sonner 通知')">
      错误通知
    </Button>
  </div>
</template>

<script setup lang="ts">
import { toast } from 'vue-sonner'
import { Button } from '@/components/ui/button' // 确保你的 Button 组件路径正确
</script>