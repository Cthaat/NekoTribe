<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue';
import { usePreferenceStore } from '@/stores/user';
import {
  Copy,
  KeyRound,
  ShieldOff,
  Smartphone
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  v2ConfirmTwoFactorSetup,
  v2DisableTwoFactor,
  v2GetSettings,
  v2StartTwoFactorSetup
} from '@/services/account';
import type { TwoFactorSetupVM } from '@/types/account';

const { t } = useAppLocale();

const loading = ref(false);
const actionPending = ref(false);
const enabled = ref<boolean | null>(null);
const statusFailed = ref(false);
const setupPassword = ref('');
const setupCode = ref('');
const disablePassword = ref('');
const disableCode = ref('');
const setup = ref<TwoFactorSetupVM | null>(null);
const recoveryCodes = ref<string[]>([]);
const preferenceStore = usePreferenceStore();
const ownerRevision = preferenceStore.authRevision();
let disposed = false;
function isCurrent(): boolean { return !disposed && preferenceStore.isAuthCurrent(ownerRevision); }
onUnmounted(() => {
  disposed = true;
  setup.value = null; recoveryCodes.value = [];
  setupPassword.value = ''; setupCode.value = ''; disablePassword.value = ''; disableCode.value = '';
});

async function loadStatus(): Promise<void> {
  if (!isCurrent() || loading.value || actionPending.value) return;
  loading.value = true;
  enabled.value = null;
  statusFailed.value = false;
  setup.value = null; recoveryCodes.value = [];
  try {
    const settings = await v2GetSettings();
    if (!isCurrent()) return;
    enabled.value = settings.twoFactorEnabled;
  } catch {
    if (!isCurrent()) return;
    statusFailed.value = true;
  } finally {
    if (isCurrent()) loading.value = false;
  }
}

async function startSetup(): Promise<void> {
  if (enabled.value !== false || actionPending.value || loading.value || !isCurrent()) return;
  if (!setupPassword.value.trim()) {
    toast.error(t('account.security.twoFactor.feedback.passwordRequired'));
    return;
  }

  setup.value = null;
  setupCode.value = '';
  recoveryCodes.value = [];
  actionPending.value = true;
  try {
    const result = await v2StartTwoFactorSetup({
      password: setupPassword.value.trim()
    });
    if (!isCurrent()) return;
    setup.value = result;
    setupCode.value = '';
    recoveryCodes.value = [];
    toast.success(t('account.security.twoFactor.feedback.setupStarted'));
  } catch (error) {
    if (!isCurrent()) return;
    toast.error(t('account.security.twoFactor.feedback.setupFailed'), {
      description: error instanceof Error ? error.message : undefined
    });
  } finally {
    if (isCurrent()) actionPending.value = false;
  }
}

async function confirmSetup(): Promise<void> {
  if (enabled.value !== false || actionPending.value || loading.value || !isCurrent()) return;
  if (!setup.value || !setupCode.value.trim()) {
    toast.error(t('account.security.twoFactor.feedback.codeRequired'));
    return;
  }

  actionPending.value = true;
  try {
    const result = await v2ConfirmTwoFactorSetup({
      code: setupCode.value.trim()
    });
    if (!isCurrent()) return;
    enabled.value = result.enabled;
    recoveryCodes.value = result.recoveryCodes;
    setup.value = null;
    setupPassword.value = '';
    setupCode.value = '';
    toast.success(t('account.security.twoFactor.feedback.enabled'));
  } catch (error) {
    if (!isCurrent()) return;
    toast.error(t('account.security.twoFactor.feedback.confirmFailed'), {
      description: error instanceof Error ? error.message : undefined
    });
  } finally {
    if (isCurrent()) actionPending.value = false;
  }
}

async function disableTwoFactor(): Promise<void> {
  if (enabled.value !== true || actionPending.value || loading.value || !isCurrent()) return;
  if (!disablePassword.value.trim() || !disableCode.value.trim()) {
    toast.error(t('account.security.twoFactor.feedback.disableRequired'));
    return;
  }

  actionPending.value = true;
  try {
    const result = await v2DisableTwoFactor({
      password: disablePassword.value.trim(),
      code: disableCode.value.trim()
    });
    if (!isCurrent()) return;
    enabled.value = result.enabled;
    disablePassword.value = '';
    disableCode.value = '';
    recoveryCodes.value = [];
    toast.success(t('account.security.twoFactor.feedback.disabled'));
  } catch (error) {
    if (!isCurrent()) return;
    toast.error(t('account.security.twoFactor.feedback.disableFailed'), {
      description: error instanceof Error ? error.message : undefined
    });
  } finally {
    if (isCurrent()) actionPending.value = false;
  }
}

function canCopySecret(value: string): boolean {
  return isCurrent() && !loading.value && !actionPending.value && enabled.value !== null &&
    (setup.value?.secret === value || (recoveryCodes.value.length > 0 && recoveryCodes.value.join('\n') === value));
}
async function copySecret(value: string): Promise<void> {
  if (!canCopySecret(value)) return;
  if (!import.meta.client) return;
  await navigator.clipboard.writeText(value);
  if (!canCopySecret(value)) return;
  toast.success(t('account.security.twoFactor.feedback.copied'));
}

onMounted(loadStatus);
</script>

<template>
  <div class="space-y-5">
    <div
      class="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/20 px-3 py-2.5"
    >
      <div class="flex items-center gap-2 text-sm">
        <Smartphone class="h-4 w-4 text-muted-foreground" />
        <span class="font-medium">
          {{ t('account.security.twoFactor.title') }}
        </span>
      </div>
      <span
        :class="[
          'inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-medium',
          enabled === true
            ? 'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300'
            : 'border-border/60 bg-muted/40 text-muted-foreground'
        ]"
      >
        {{
          enabled === null
            ? (loading ? t('account.security.twoFactor.statusLoading') : t('account.security.twoFactor.statusUnknown'))
            : enabled
            ? t('account.security.twoFactor.enabled')
            : t('account.security.twoFactor.disabled')
        }}
      </span>
    </div>

    <p v-if="statusFailed" role="alert" class="text-sm text-destructive">{{ t('account.security.twoFactor.feedback.loadFailed') }}</p>
    <Button variant="outline" :disabled="loading || actionPending" @click="loadStatus">{{ t('account.security.twoFactor.reloadStatus') }}</Button>
    <div v-if="enabled === false" class="grid gap-4">
      <div class="grid gap-2">
        <Label for="two-factor-setup-password" class="text-xs font-medium">
          {{ t('account.security.twoFactor.password') }}
        </Label>
        <div class="flex flex-col gap-2 sm:flex-row">
          <Input
            id="two-factor-setup-password"
            v-model="setupPassword"
            type="password"
            autocomplete="current-password"
            :disabled="loading || actionPending"
            :placeholder="t('account.security.twoFactor.passwordPlaceholder')"
            class="h-9 shadow-xs"
          />
          <Button
            class="h-9 shrink-0 rounded-md shadow-xs"
            :disabled="loading || actionPending"
            @click="startSetup"
          >
            <KeyRound class="h-3.5 w-3.5" />
            {{ t('account.security.twoFactor.startSetup') }}
          </Button>
        </div>
      </div>

      <div
        v-if="setup"
        class="grid gap-4 rounded-lg border border-border/60 bg-muted/30 p-3"
      >
        <div class="grid gap-2">
          <Label for="two-factor-secret" class="text-xs font-medium">
            {{ t('account.security.twoFactor.secret') }}
          </Label>
          <div class="flex flex-col gap-2 sm:flex-row">
            <Input
              id="two-factor-secret"
              :model-value="setup.secret"
              readonly
              class="h-9 font-mono text-xs shadow-xs"
            />
            <Button
              type="button"
              variant="outline"
              class="h-9 shrink-0 rounded-md shadow-xs"
              @click="copySecret(setup.secret)"
            >
              <Copy class="h-3.5 w-3.5" />
              {{ t('common.copy') }}
            </Button>
          </div>
          <p class="break-all rounded-md bg-background/60 px-2 py-1 font-mono text-[11px] text-muted-foreground">
            {{ setup.otpauthUrl }}
          </p>
        </div>
        <div class="grid gap-2">
          <Label for="two-factor-confirm-code" class="text-xs font-medium">
            {{ t('account.security.twoFactor.code') }}
          </Label>
          <div class="flex flex-col gap-2 sm:flex-row">
            <Input
              id="two-factor-confirm-code"
              v-model="setupCode"
              inputmode="numeric"
              autocomplete="one-time-code"
              :disabled="actionPending"
              :placeholder="t('account.security.twoFactor.codePlaceholder')"
              class="h-9 shadow-xs"
              @keydown.enter.prevent="confirmSetup"
            />
            <Button
              class="h-9 shrink-0 rounded-md shadow-xs"
              :disabled="actionPending"
              @click="confirmSetup"
            >
              {{ t('account.security.twoFactor.confirm') }}
            </Button>
          </div>
        </div>
      </div>
    </div>

    <div v-else-if="enabled === true" class="grid gap-4">
      <div class="grid gap-2">
        <Label for="two-factor-disable-password" class="text-xs font-medium">
          {{ t('account.security.twoFactor.password') }}
        </Label>
        <Input
          id="two-factor-disable-password"
          v-model="disablePassword"
          type="password"
          autocomplete="current-password"
          :disabled="actionPending"
          :placeholder="t('account.security.twoFactor.passwordPlaceholder')"
          class="h-9 shadow-xs"
        />
      </div>
      <div class="grid gap-2">
        <Label for="two-factor-disable-code" class="text-xs font-medium">
          {{ t('account.security.twoFactor.codeOrRecovery') }}
        </Label>
        <div class="flex flex-col gap-2 sm:flex-row">
          <Input
            id="two-factor-disable-code"
            v-model="disableCode"
            autocomplete="one-time-code"
            :disabled="actionPending"
            :placeholder="t('account.security.twoFactor.codePlaceholder')"
            class="h-9 shadow-xs"
            @keydown.enter.prevent="disableTwoFactor"
          />
          <Button
            variant="destructive"
            class="h-9 shrink-0 rounded-md shadow-xs"
            :disabled="actionPending"
            @click="disableTwoFactor"
          >
            <ShieldOff class="h-3.5 w-3.5" />
            {{ t('account.security.twoFactor.disable') }}
          </Button>
        </div>
      </div>
    </div>

    <div
      v-if="recoveryCodes.length > 0"
      class="space-y-2 rounded-lg border border-amber-200/60 bg-amber-50/50 p-3 dark:border-amber-900/40 dark:bg-amber-950/30"
    >
      <p class="text-sm font-medium text-amber-800 dark:text-amber-200">
        {{ t('account.security.twoFactor.recoveryCodes') }}
      </p>
      <div class="grid gap-1.5 sm:grid-cols-2">
        <code
          v-for="code in recoveryCodes"
          :key="code"
          class="rounded-md border border-amber-200/60 bg-white/60 px-2 py-1 font-mono text-xs text-amber-900 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-200"
        >
          {{ code }}
        </code>
      </div>
    </div>
  </div>
</template>
