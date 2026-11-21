<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
import { Loader2, Save, Settings as SettingsIcon } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Skeleton } from '@/components/ui/skeleton';
import { Switch } from '@/components/ui/switch';
import {
  getModerationSettings,
  updateModerationSettings
} from '@/services';
import type { ModerationSettingVM } from '@/types/moderation';

const { t } = useAppLocale();
const queue = authQueueFor(useNuxtApp());
const owner = queue.revision;
const current = () => !disposed && !queue.isIdentityChanging && queue.revision === owner;
let disposed = false;

const settings = ref<ModerationSettingVM[]>([]);
const loading = ref(false);
const saving = ref(false);
let previous = new Map<string, string>();

function replaceSettings(items: ModerationSettingVM[]) {
  settings.value = items;
  previous = new Map(items.map(item => [item.key, item.value]));
}

function boolValue(value: string): boolean {
  return value === 'true' || value === '1';
}

function updateBool(setting: ModerationSettingVM, value: boolean): void {
  setting.value = value ? 'true' : 'false';
}

function settingLabel(setting: ModerationSettingVM): string {
  return t(`moderation.settings.definitions.${setting.key}.label`);
}

function settingDescription(setting: ModerationSettingVM): string {
  return t(`moderation.settings.definitions.${setting.key}.description`);
}

async function loadSettings(): Promise<void> {
  if (!current()) return;
  loading.value = true;
  try {
    const items = await getModerationSettings();
    if (current()) replaceSettings(items);
  } catch (error) {
    if (!current()) return;
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    if (current()) loading.value = false;
  }
}

async function saveSettings(): Promise<void> {
  if (!current() || loading.value || saving.value) return;
  const changed = settings.value.filter(item => previous.get(item.key) !== item.value);
  if (!changed.length) return;
  saving.value = true;
  try {
    const items = await updateModerationSettings(changed);
    if (!current()) return;
    replaceSettings(items);
    toast.success(t('moderation.settings.saved'));
  } catch (error) {
    if (!current()) return;
    toast.error(t('moderation.settings.saveFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    if (current()) saving.value = false;
  }
}

let unsubscribe: (() => void) | undefined;
onMounted(() => {
  unsubscribe = queue.subscribe(() => {
    if (current()) return;
    replaceSettings([]);
    loading.value = false;
    saving.value = false;
  });
  void loadSettings();
});
onUnmounted(() => {
  disposed = true;
  unsubscribe?.();
});
</script>

<template>
  <div class="grid gap-4">
    <section
      class="flex flex-col gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:flex-row sm:items-center sm:justify-between"
    >
      <div class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
        >
          <SettingsIcon class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('moderation.settings.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('moderation.settings.description') }}
          </p>
        </div>
      </div>
      <Button
        class="h-9 rounded-md shadow-xs sm:w-auto"
        :disabled="loading || saving || !settings.length"
        @click="saveSettings"
      >
        <Loader2 v-if="saving" class="h-3.5 w-3.5 animate-spin" />
        <Save v-else class="h-3.5 w-3.5" />
        {{ saving ? t('common.processing') : t('common.submit') }}
      </Button>
    </section>

    <div v-if="loading" class="grid gap-4 md:grid-cols-2">
      <div
        v-for="item in 4"
        :key="item"
        class="rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <Skeleton class="h-32 rounded-lg" />
      </div>
    </div>

    <div v-else class="grid gap-4 md:grid-cols-2">
      <article
        v-for="setting in settings"
        :key="setting.key"
        class="grid gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none transition-all hover:border-border hover:shadow-md"
      >
        <header class="grid gap-1">
          <h3 class="text-sm font-semibold tracking-tight">
            {{ settingLabel(setting) }}
          </h3>
          <p class="text-xs text-muted-foreground">
            {{ settingDescription(setting) }}
          </p>
        </header>
        <div
          v-if="setting.valueType === 'boolean'"
          class="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <span class="font-mono text-xs text-muted-foreground">
            {{ setting.key }}
          </span>
          <Switch
            :model-value="boolValue(setting.value)"
            :disabled="saving"
            @update:model-value="updateBool(setting, Boolean($event))"
          />
        </div>
        <Input
          v-else
          v-model="setting.value"
          class="h-9 shadow-xs"
          :type="setting.valueType === 'number' ? 'number' : 'text'"
          :disabled="saving"
        />
      </article>
    </div>
  </div>
</template>
