<script setup lang="ts">
import { Separator } from '@/components/ui/separator';
import SecurityPage from '@/components/SecurityPage.vue';
</script>

<template>
  <Card>
    <CardContent>
      <div class="hidden space-y-6 p-10 pb-16 md:block">
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            {{ $t('account.security.title') }}
          </h2>
          <p class="text-muted-foreground">
            {{ $t('account.security.description') }}
          </p>
        </div>
        <Separator class="my-6" />
        <SecurityPage />
      </div>
    </CardContent>
  </Card>
</template>
