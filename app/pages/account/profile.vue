<script setup lang="ts">
import { Separator } from '@/components/ui/separator';
import ProfileForm from '@/components/ProfileForm.vue';

const { t } = useAppLocale();
</script>

<template>
  <Card>
    <CardContent>
      <div class="space-y-6 p-4 pb-8 sm:p-6 md:p-10 md:pb-16">
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            {{ t('account.profile.title') }}
          </h2>
          <p class="text-muted-foreground">
            {{ t('account.profile.description') }}
          </p>
        </div>
        <Separator class="my-6" />
        <ProfileForm />
      </div>
    </CardContent>
  </Card>
</template>
