<script lang="ts" setup>
import SecurityPagePasswordForm from '@/components/SecurityPagePasswordForm.vue';
import SecurityPageEmail from '@/components/SecurityPageEmail.vue';
import SecurityPageTwoFactor from '@/components/SecurityPageTwoFactor.vue';
import SecurityPageDangerZone from '@/components/SecurityPageDangerZone.vue';

const { t } = useAppLocale();
</script>

<template>
  <h2 class="text-lg font-bold tracking-tight">
    {{ t('account.security.securityPage.password.title') }}
  </h2>
  <p class="text-xs text-muted-foreground">
    {{
      t(
        'account.security.securityPage.password.description'
      )
    }}
  </p>
  <SecurityPagePasswordForm />
  <!-- 分割线 -->
  <Separator class="my-6" />
  <SecurityPageTwoFactor />
  <Separator class="my-6" />
  <h2 class="text-lg font-bold tracking-tight">{{ t('account.security.securityPage.email.title') }}</h2>
  <p class="text-xs text-muted-foreground">
    {{
      t(
        'account.security.securityPage.email.description'
      )
    }}
  </p>
  <SecurityPageEmail />
  <Separator class="my-6" />
  <SecurityPageDangerZone />
</template>
