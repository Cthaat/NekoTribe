<script lang="ts" setup>
import { KeyRound, Mail, ShieldCheck } from 'lucide-vue-next';
import SecurityPagePasswordForm from '@/components/SecurityPagePasswordForm.vue';
import SecurityPageEmail from '@/components/SecurityPageEmail.vue';
import SecurityPageTwoFactor from '@/components/SecurityPageTwoFactor.vue';
import SecurityPageDangerZone from '@/components/SecurityPageDangerZone.vue';

const { t } = useAppLocale();
</script>

<template>
  <div class="space-y-6">
    <section
      class="rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="mb-5 flex items-start gap-3">
        <div
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
        >
          <KeyRound class="h-4 w-4" />
        </div>
        <div class="min-w-0 space-y-1">
          <h2 class="text-base font-semibold tracking-tight">
            {{ t('account.security.securityPage.password.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.security.securityPage.password.description') }}
          </p>
        </div>
      </header>
      <SecurityPagePasswordForm />
    </section>

    <section
      class="rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="mb-5 flex items-start gap-3">
        <div
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
        >
          <ShieldCheck class="h-4 w-4" />
        </div>
        <div class="min-w-0 space-y-1">
          <h2 class="text-base font-semibold tracking-tight">
            {{ t('account.security.twoFactor.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.security.twoFactor.description') }}
          </p>
        </div>
      </header>
      <SecurityPageTwoFactor />
    </section>

    <section
      class="rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="mb-5 flex items-start gap-3">
        <div
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
        >
          <Mail class="h-4 w-4" />
        </div>
        <div class="min-w-0 space-y-1">
          <h2 class="text-base font-semibold tracking-tight">
            {{ t('account.security.securityPage.email.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.security.securityPage.email.description') }}
          </p>
        </div>
      </header>
      <SecurityPageEmail />
    </section>

    <SecurityPageDangerZone />
  </div>
</template>
