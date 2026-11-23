<script setup lang="ts">
const { t } = useAppLocale();
const localePath = useLocalePath();
</script>

<template>
  <div class="space-y-4">
    <AccountResources quota-first />
    <NuxtLink :to="localePath('/account/ai-provider')" class="inline-flex px-4 pb-4 text-sm font-medium text-primary underline-offset-4 hover:underline">
      {{ t('aiUserProvider.title') }}
    </NuxtLink>
  </div>
</template>
