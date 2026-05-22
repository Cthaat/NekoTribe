<script setup lang="ts">
import { ref, onMounted } from 'vue';
import {
  Bell,
  Eye,
  Loader2,
  RefreshCw,
  Save,
  Settings as SettingsIcon,
  ShieldCheck
} from 'lucide-vue-next';
import AiSentimentControlPanel from '@/components/AiSentimentControlPanel.vue';
import SecurityPage from '@/components/SecurityPage.vue';
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

const loginAlerts = ref(true);
const profileVisibility = ref<'public' | 'private'>('public');
const showOnlineStatus = ref(true);
const allowDmFromStrangers = ref(false);
const pushNotificationEnabled = ref(true);
const emailNotificationEnabled = ref(true);

async function loadSettings(): Promise<void> {
  loading.value = true;
  try {
    const settings = await v2GetSettings();
    loginAlerts.value = settings.loginAlerts;
    profileVisibility.value =
      (settings.profileVisibility as 'public' | 'private') || 'public';
    showOnlineStatus.value = settings.showOnlineStatus;
    allowDmFromStrangers.value = settings.allowDmFromStrangers;
    pushNotificationEnabled.value = settings.pushNotificationEnabled;
    emailNotificationEnabled.value = settings.emailNotificationEnabled;
  } catch {
    toast.error(t('account.settings.feedback.loadFailed'));
  } finally {
    loading.value = false;
  }
}

async function saveSettings(): Promise<void> {
  saving.value = true;
  try {
    await v2PatchSettings({
      loginAlerts: loginAlerts.value,
      profileVisibility: profileVisibility.value,
      showOnlineStatus: showOnlineStatus.value,
      allowDmFromStrangers: allowDmFromStrangers.value,
      pushNotificationEnabled: pushNotificationEnabled.value,
      emailNotificationEnabled: emailNotificationEnabled.value
    });
    toast.success(t('account.settings.feedback.saved'));
  } catch {
    toast.error(t('account.settings.feedback.saveFailed'));
  } finally {
    saving.value = false;
  }
}

onMounted(loadSettings);
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header
        class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
      >
        <div class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <SettingsIcon class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-lg font-semibold tracking-tight">
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
            class="h-9 rounded-md shadow-xs"
            :disabled="loading || saving"
            @click="loadSettings()"
          >
            <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
            <RefreshCw v-else class="h-3.5 w-3.5" />
            {{ t('common.refresh') }}
          </Button>
          <Button
            class="h-9 rounded-md shadow-xs"
            :disabled="loading || saving"
            @click="saveSettings()"
          >
            <Loader2 v-if="saving" class="h-3.5 w-3.5 animate-spin" />
            <Save v-else class="h-3.5 w-3.5" />
            {{ t('account.settings.save') }}
          </Button>
        </div>
      </header>
    </section>

    <SecurityPage />

    <AiSentimentControlPanel />

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
        >
          <Eye class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h3 class="text-base font-semibold tracking-tight">
            {{ t('account.settings.privacy') }}
          </h3>
        </div>
      </header>

      <div class="grid gap-3">
        <div
          class="flex flex-col gap-3 rounded-lg border border-border/60 bg-muted/20 p-4 sm:flex-row sm:items-center sm:justify-between"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.visibility') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.visibilityDesc') }}
            </div>
          </div>
          <Select v-model="profileVisibility">
            <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
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

        <div
          class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-muted/20 p-4"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.showOnline') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.showOnlineDesc') }}
            </div>
          </div>
          <Switch v-model:checked="showOnlineStatus" />
        </div>

        <div
          class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-muted/20 p-4"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.allowDM') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.allowDMDesc') }}
            </div>
          </div>
          <Switch v-model:checked="allowDmFromStrangers" />
        </div>
      </div>
    </section>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
        >
          <Bell class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h3 class="text-base font-semibold tracking-tight">
            {{ t('account.settings.notifications') }}
          </h3>
        </div>
      </header>

      <div class="grid gap-3">
        <div
          class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-muted/20 p-4"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.push') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.pushDesc') }}
            </div>
          </div>
          <Switch v-model:checked="pushNotificationEnabled" />
        </div>
        <div
          class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-muted/20 p-4"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.email') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.emailDesc') }}
            </div>
          </div>
          <Switch v-model:checked="emailNotificationEnabled" />
        </div>
      </div>
    </section>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
        >
          <ShieldCheck class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h3 class="text-base font-semibold tracking-tight">
            {{ t('account.settings.securityOther') }}
          </h3>
        </div>
      </header>

      <div class="grid gap-3">
        <div
          class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-muted/20 p-4"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">
              {{ t('account.settings.loginAlerts') }}
            </div>
            <div class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.settings.loginAlertsDesc') }}
            </div>
          </div>
          <Switch v-model:checked="loginAlerts" />
        </div>
      </div>
    </section>
  </div>
</template>
