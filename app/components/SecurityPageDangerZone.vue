<script setup lang="ts">
import { ref } from 'vue';
import { AlertTriangle } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { v2DeleteMe } from '@/services/account';
import { usePreferenceStore } from '@/stores/user';

const { t } = useAppLocale();
const localePath = useLocalePath();
const preferenceStore = usePreferenceStore();

const password = ref('');
const confirmation = ref('');
const pending = ref(false);

async function deleteAccount(): Promise<void> {
  if (!password.value.trim() || !confirmation.value.trim()) {
    toast.error(t('account.security.danger.feedback.required'));
    return;
  }

  pending.value = true;
  try {
    await v2DeleteMe({
      password: password.value,
      confirmation: confirmation.value
    });
    preferenceStore.resetToDefaults();
    toast.success(t('account.security.danger.feedback.deleted'));
    await navigateTo(localePath('/auth/login'));
  } catch (error) {
    toast.error(t('account.security.danger.feedback.deleteFailed'), {
      description: error instanceof Error ? error.message : undefined
    });
  } finally {
    pending.value = false;
  }
}
</script>

<template>
  <section class="space-y-4 rounded-lg border border-destructive/30 p-4">
    <div class="flex items-start gap-3">
      <AlertTriangle class="mt-0.5 h-4 w-4 text-destructive" />
      <div class="min-w-0 space-y-1">
        <h2 class="text-lg font-bold tracking-tight text-destructive">
          {{ t('account.security.danger.title') }}
        </h2>
        <p class="text-sm text-muted-foreground">
          {{ t('account.security.danger.description') }}
        </p>
      </div>
    </div>

    <div class="grid gap-4">
      <div class="grid gap-2">
        <Label for="delete-account-password">
          {{ t('account.security.currentPassword') }}
        </Label>
        <Input
          id="delete-account-password"
          v-model="password"
          type="password"
          autocomplete="current-password"
          :disabled="pending"
          :placeholder="t('account.security.currentPasswordPlaceholder')"
        />
      </div>
      <div class="grid gap-2">
        <Label for="delete-account-confirmation">
          {{ t('account.security.danger.confirmation') }}
        </Label>
        <Input
          id="delete-account-confirmation"
          v-model="confirmation"
          :disabled="pending"
          :placeholder="t('account.security.danger.confirmationPlaceholder')"
        />
      </div>
      <Button
        variant="destructive"
        class="w-full sm:w-fit"
        :disabled="pending"
        @click="deleteAccount"
      >
        {{ t('account.security.danger.delete') }}
      </Button>
    </div>
  </section>
</template>
