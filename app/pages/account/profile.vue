<script setup lang="ts">
import { UserCog } from 'lucide-vue-next';
import ProfileForm from '@/components/ProfileForm.vue';

const { t } = useAppLocale();
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
        >
          <UserCog class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('account.profile.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.profile.description') }}
          </p>
        </div>
      </header>
    </section>

    <ProfileForm />
  </div>
</template>
