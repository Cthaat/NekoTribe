<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted } from 'vue';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import { desktopNotificationsEnabled, desktopNotificationsSupported, setDesktopNotificationsEnabled } from '@/utils/desktop-notifications';
import type { AccountSettingsVM, UpdateAccountSettingsFormVM } from '@/types/account';
import {
  Bell,
  Eye,
  Loader2,
  RefreshCw,
  Save,
  Settings as SettingsIcon,
  ShieldCheck
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Switch } from '@/components/ui/switch';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import {
  v2GetSettings,
  v2PatchSettings
} from '@/services';
import { toast } from 'vue-sonner';

const { t } = useAppLocale();

const loading = ref(false);
const saving = ref(false);
const snapshot = ref<AccountSettingsVM | null>(null);
const statusFailed = ref(false);
const saveUncertain = ref(false);
const queue = authQueueFor(useNuxtApp());
const account = usePreferenceStore();
const ownerRevision = queue.revision;
let disposed = false;
function isCurrent(): boolean {
  return !disposed && !queue.isIdentityChanging && queue.revision === ownerRevision;
}
onUnmounted(() => {
  disposed = true;
  snapshot.value = null;
  if (typeof window !== 'undefined') window.removeEventListener('focus', readDesktopState);
});

const loginAlerts = ref(true);
const profileVisibility = ref('');
const showOnlineStatus = ref(true);
const allowDmFromStrangers = ref(false);
const pushNotificationEnabled = ref(true);
const emailNotificationEnabled = ref(true);
const desktopEnabled = ref(false);
const desktopChanging = ref(false);
const desktopPermission = ref<NotificationPermission | 'unsupported' | null>(null);
const desktopFailed = ref(false);

function readDesktopState() {
  if (!isCurrent()) return;
  desktopPermission.value = desktopNotificationsSupported() ? window.Notification.permission : 'unsupported';
  desktopEnabled.value = desktopNotificationsEnabled(account.preferences.user.id);
}

async function toggleDesktopNotifications() {
  if (!isCurrent() || desktopChanging.value || !desktopNotificationsSupported()) return;
  const userId = account.preferences.user.id;
  const enable = !desktopEnabled.value;
  desktopChanging.value = true;
  desktopFailed.value = false;
  try {
    const permission = enable && window.Notification.permission === 'default'
      ? await window.Notification.requestPermission() : window.Notification.permission;
    if (!isCurrent() || account.preferences.user.id !== userId) return;
    desktopPermission.value = permission;
    if (enable && permission !== 'granted') return;
    desktopFailed.value = !setDesktopNotificationsEnabled(userId, enable);
    desktopEnabled.value = desktopNotificationsEnabled(userId);
  } catch {
    if (isCurrent()) desktopFailed.value = true;
  } finally {
    desktopChanging.value = false;
  }
}

function applySettings(settings: AccountSettingsVM): void {
  loginAlerts.value = settings.loginAlerts;
  profileVisibility.value = settings.profileVisibility;
  showOnlineStatus.value = settings.showOnlineStatus;
  allowDmFromStrangers.value = settings.allowDmFromStrangers;
  pushNotificationEnabled.value = settings.pushNotificationEnabled;
  emailNotificationEnabled.value = settings.emailNotificationEnabled;
  snapshot.value = { ...settings };
}

function settingsPatch(): UpdateAccountSettingsFormVM | null {
  const previous = snapshot.value;
  if (!previous) return null;
  const patch: UpdateAccountSettingsFormVM = {};
  if (loginAlerts.value !== previous.loginAlerts) patch.loginAlerts = loginAlerts.value;
  if (showOnlineStatus.value !== previous.showOnlineStatus) patch.showOnlineStatus = showOnlineStatus.value;
  if (allowDmFromStrangers.value !== previous.allowDmFromStrangers) patch.allowDmFromStrangers = allowDmFromStrangers.value;
  if (pushNotificationEnabled.value !== previous.pushNotificationEnabled) patch.pushNotificationEnabled = pushNotificationEnabled.value;
  if (emailNotificationEnabled.value !== previous.emailNotificationEnabled) patch.emailNotificationEnabled = emailNotificationEnabled.value;
  if (profileVisibility.value !== previous.profileVisibility) {
    if (profileVisibility.value !== 'public' && profileVisibility.value !== 'private') return null;
    patch.profileVisibility = profileVisibility.value;
  }
  return patch;
}
const canSave = computed(() => {
  const patch = settingsPatch();
  return !loading.value && !saving.value && patch !== null && Object.keys(patch).length > 0;
});

async function loadSettings(): Promise<void> {
  if (!isCurrent() || loading.value || saving.value) return;
  loading.value = true;
  snapshot.value = null;
  statusFailed.value = false;
  try {
    const settings = await v2GetSettings();
    if (!isCurrent()) return;
    applySettings(settings);
    saveUncertain.value = false;
  } catch {
    if (!isCurrent()) return;
    statusFailed.value = true;
    toast.error(t('account.settings.feedback.loadFailed'));
  } finally {
    if (isCurrent()) loading.value = false;
  }
}

async function saveSettings(): Promise<void> {
  if (!isCurrent() || loading.value || saving.value) return;
  const patch = settingsPatch();
  if (!patch || Object.keys(patch).length === 0) return;
  saving.value = true;
  try {
    const settings = await v2PatchSettings(patch);
    if (!isCurrent()) return;
    applySettings(settings);
    toast.success(t('account.settings.feedback.saved'));
  } catch {
    if (!isCurrent()) return;
    snapshot.value = null;
    saveUncertain.value = true;
    toast.error(t('account.settings.feedback.saveUncertain'));
  } finally {
    if (isCurrent()) saving.value = false;
  }
}

onMounted(() => {
  void loadSettings();
  readDesktopState();
  window.addEventListener('focus', readDesktopState);
});
</script>

<template>
  <div class="grid gap-4">
    <section class="grid gap-4 rounded-2xl bg-[var(--hover)]/80 p-5 sm:p-6">
      <header
        class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
      >
        <div class="flex items-start gap-3">
          <span
            class="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary"
          >
            <SettingsIcon class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-lg font-bold tracking-tight">
              {{ t('account.settings.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t('account.settings.description') }}
            </p>
          </div>
        </div>
        <div class="flex flex-col gap-2 sm:flex-row">
          <Button
            variant="outline"
              size="icon"
              class="size-9 border-[var(--divider)]"
              :aria-label="t('common.refresh')"
              :title="t('common.refresh')"
            :disabled="loading || saving"
            @click="loadSettings()"
          >
            <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
            <RefreshCw v-else class="h-3.5 w-3.5" />
          </Button>
          <Button
            :variant="canSave ? 'default' : 'secondary'"
            class="pressable h-9 rounded-full disabled:opacity-70"
            :disabled="!canSave"
            @click="saveSettings()"
          >
            <Loader2 v-if="saving" class="h-3.5 w-3.5 animate-spin" />
            <Save v-else class="h-3.5 w-3.5" />
            {{ t('account.settings.save') }}
          </Button>
        </div>
      </header>
    </section>

    <p v-if="loading" role="status" class="text-sm text-muted-foreground">{{ t('account.settings.feedback.loading') }}</p>
    <p v-else-if="statusFailed" role="alert" class="text-sm text-destructive">{{ t('account.settings.feedback.loadFailed') }}</p>
    <p v-else-if="saveUncertain" role="alert" class="text-sm text-destructive">{{ t('account.settings.feedback.saveUncertain') }}</p>
    <template v-if="snapshot">

    <section class="grid gap-3 rounded-2xl bg-[var(--hover)]/80 p-5 sm:p-6">
      <header class="flex items-center gap-3 pb-1">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-sky-500/12 text-sky-600 dark:text-sky-400"
        >
          <Eye class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h3 class="text-base font-semibold tracking-tight">
            {{ t('account.settings.privacy') }}
          </h3>
        </div>
      </header>

      <div class="divide-y divide-[var(--divider)] rounded-xl bg-background/70 px-4">
        <div
          class="flex min-h-[56px] flex-col gap-3 py-3.5 sm:flex-row sm:items-center sm:justify-between"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.visibility') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.visibilityDesc') }}
            </div>
          </div>
          <Select v-model="profileVisibility" :disabled="loading || saving">
            <SelectTrigger class="h-9 w-full rounded-full sm:w-[160px]">
              <SelectValue placeholder="-" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="public">
                {{ t('account.settings.visibilityPublic') }}
              </SelectItem>
              <SelectItem value="private">
                {{ t('account.settings.visibilityPrivate') }}
              </SelectItem>
            </SelectContent>
          </Select>
        </div>

        <div class="flex min-h-[56px] items-center justify-between gap-4 py-3.5">
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.showOnline') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.showOnlineDesc') }}
            </div>
          </div>
          <Switch v-model:checked="showOnlineStatus" :disabled="loading || saving" />
        </div>

        <div class="flex min-h-[56px] items-center justify-between gap-4 py-3.5">
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.allowDM') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.allowDMDesc') }}
            </div>
          </div>
          <Switch v-model:checked="allowDmFromStrangers" :disabled="loading || saving" />
        </div>
      </div>
    </section>

    <section class="grid gap-3 rounded-2xl bg-[var(--hover)]/80 p-5 sm:p-6">
      <header class="flex items-center gap-3 pb-1">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-violet-500/12 text-violet-600 dark:text-violet-400"
        >
          <Bell class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h3 class="text-base font-semibold tracking-tight">
            {{ t('account.settings.notifications') }}
          </h3>
        </div>
      </header>

      <div class="divide-y divide-[var(--divider)] rounded-xl bg-background/70 px-4">
        <div class="flex min-h-[56px] items-center justify-between gap-4 py-3.5">
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.push') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.pushDesc') }}
            </div>
          </div>
          <Switch v-model:checked="pushNotificationEnabled" :disabled="loading || saving" />
        </div>
        <div class="flex min-h-[56px] items-center justify-between gap-4 py-3.5">
          <div class="min-w-0">
            <div class="text-sm font-medium">{{ t('notifications.desktop.setting') }}</div>
            <p class="mt-0.5 text-xs text-muted-foreground" role="status">
              {{ t(desktopFailed ? 'notifications.desktop.error' : desktopPermission === 'unsupported' ? 'notifications.desktop.unsupported' :
                desktopPermission === 'denied' ? 'notifications.desktop.denied' : 'notifications.desktop.description') }}
            </p>
          </div>
          <Button
            type="button" size="sm" variant="outline" class="rounded-full" :aria-pressed="desktopEnabled"
            :disabled="desktopChanging || desktopPermission === null || desktopPermission === 'unsupported' || (!desktopEnabled && desktopPermission === 'denied')"
            @click="toggleDesktopNotifications"
          >
            {{ t(desktopEnabled ? 'notifications.desktop.disable' : 'notifications.desktop.enable') }}
          </Button>
        </div>
        <div class="flex min-h-[56px] items-center justify-between gap-4 py-3.5">
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.email') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.emailDesc') }}
            </div>
          </div>
          <Switch v-model:checked="emailNotificationEnabled" :disabled="loading || saving" />
        </div>
      </div>
    </section>

    <section class="grid gap-3 rounded-2xl bg-[var(--hover)]/80 p-5 sm:p-6">
      <header class="flex items-center gap-3 pb-1">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-emerald-500/12 text-emerald-600 dark:text-emerald-400"
        >
          <ShieldCheck class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h3 class="text-base font-semibold tracking-tight">
            {{ t('account.settings.securityOther') }}
          </h3>
        </div>
      </header>

      <div class="divide-y divide-[var(--divider)] rounded-xl bg-background/70 px-4">
        <div class="flex min-h-[56px] items-center justify-between gap-4 py-3.5">
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.loginAlerts') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.loginAlertsDesc') }}
            </div>
          </div>
          <Switch v-model:checked="loginAlerts" :disabled="loading || saving" />
        </div>
      </div>
    </section>
    </template>
  </div>
</template>
