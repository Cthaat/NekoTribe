<script setup lang="ts">
import { Separator } from '@/components/ui/separator';
import ProfileForm from '@/components/ProfileForm.vue';
</script>

<template>
  <Card>
    <CardContent>
      <div class="hidden space-y-6 p-10 pb-16 md:block">
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            Profile
          </h2>
          <p class="text-muted-foreground">
            This is how others will see you on the site.
          </p>
        </div>
        <Separator class="my-6" />
        <ProfileForm />
      </div>
    </CardContent>
  </Card>
</template>
