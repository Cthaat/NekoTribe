<script setup lang="ts">
import { apiFetch } from '@/composables/useApi';

onMounted(async () => {
  // 这里可以添加一些初始化逻辑
  const response: any = await apiFetch(
    '/api/v1/system/config',
    {
      method: 'GET'
    }
  );
  console.log('Overview component mounted：', response);

  data.value = response.data;
});

const data = ref<any>(null);
</script>

<template>{{ data }}</template>
