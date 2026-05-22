<script setup lang="ts">
import { ref } from 'vue';
import { AlertTriangle, Trash2 } from 'lucide-vue-next';
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
  <section
    class="rounded-xl border border-destructive/30 bg-destructive/[0.02] p-5 shadow-none sm:p-6"
  >
    <header class="mb-5 flex items-start gap-3">
      <div
        class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-destructive/10 text-destructive"
      >
        <AlertTriangle class="h-4 w-4" />
      </div>
      <div class="min-w-0 space-y-1">
        <h2 class="text-base font-semibold tracking-tight text-destructive">
          {{ t('account.security.danger.title') }}
        </h2>
        <p class="text-xs text-muted-foreground">
          {{ t('account.security.danger.description') }}
        </p>
      </div>
    </header>

    <div class="grid gap-4">
      <div class="grid gap-2">
        <Label for="delete-account-password" class="text-xs font-medium">
          {{ t('account.security.currentPassword') }}
        </Label>
        <Input
          id="delete-account-password"
          v-model="password"
          type="password"
          autocomplete="current-password"
          :disabled="pending"
          :placeholder="t('account.security.currentPasswordPlaceholder')"
          class="h-9 shadow-xs"
        />
      </div>
      <div class="grid gap-2">
        <Label for="delete-account-confirmation" class="text-xs font-medium">
          {{ t('account.security.danger.confirmation') }}
        </Label>
        <Input
          id="delete-account-confirmation"
          v-model="confirmation"
          :disabled="pending"
          :placeholder="t('account.security.danger.confirmationPlaceholder')"
          class="h-9 shadow-xs"
        />
      </div>
      <Button
        variant="destructive"
        class="h-9 w-full rounded-md shadow-xs sm:w-fit"
        :disabled="pending"
        @click="deleteAccount"
      >
        <Trash2 class="h-3.5 w-3.5" />
        {{ t('account.security.danger.delete') }}
      </Button>
    </div>
  </section>
</template>
