<script setup lang="ts">
import AccountSessionGate from '@/components/AccountSessionGate.vue';
import AccountSettingsPreferences from '@/components/AccountSettingsPreferences.vue';
import AccountVisibilitySettings from '@/components/AccountVisibilitySettings.vue';
import SecurityPage from '@/components/SecurityPage.vue';
</script>

<template>
  <div class="grid gap-4">
    <AccountSessionGate>
      <AccountSettingsPreferences />
    </AccountSessionGate>
    <AccountSessionGate>
      <AccountVisibilitySettings />
    </AccountSessionGate>
    <SecurityPage />
  </div>
</template>
