<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { Save } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Switch } from '@/components/ui/switch';
import {
  getModerationSettings,
  updateModerationSettings
} from '@/services';
import type { ModerationSettingVM } from '@/types/moderation';

const { t } = useAppLocale();

const settings = ref<ModerationSettingVM[]>([]);
const loading = ref(false);
const saving = ref(false);

function boolValue(value: string): boolean {
  return value === 'true' || value === '1';
}

function updateBool(setting: ModerationSettingVM, value: boolean): void {
  setting.value = value ? 'true' : 'false';
}

async function loadSettings(): Promise<void> {
  loading.value = true;
  try {
    settings.value = await getModerationSettings();
  } catch (error) {
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    loading.value = false;
  }
}

async function saveSettings(): Promise<void> {
  saving.value = true;
  try {
    settings.value = await updateModerationSettings(settings.value);
    toast.success(t('moderation.settings.saved'));
  } catch (error) {
    toast.error(t('moderation.settings.saveFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    saving.value = false;
  }
}

onMounted(() => {
  void loadSettings();
});
</script>

<template>
  <div class="space-y-4">
    <Card>
      <CardHeader class="flex flex-row items-center justify-between space-y-0">
        <div>
          <CardTitle>{{ t('moderation.settings.title') }}</CardTitle>
          <CardDescription>{{ t('moderation.settings.description') }}</CardDescription>
        </div>
        <Button class="gap-2" :disabled="saving" @click="saveSettings">
          <Save class="h-4 w-4" />
          {{ saving ? t('common.processing') : t('common.submit') }}
        </Button>
      </CardHeader>
    </Card>

    <div v-if="loading" class="grid gap-4 md:grid-cols-2">
      <Card v-for="item in 4" :key="item">
        <CardContent class="h-32 animate-pulse bg-muted/50" />
      </Card>
    </div>

    <div v-else class="grid gap-4 md:grid-cols-2">
      <Card v-for="setting in settings" :key="setting.key">
        <CardHeader>
          <CardTitle class="text-base">{{ setting.label }}</CardTitle>
          <CardDescription>{{ setting.description }}</CardDescription>
        </CardHeader>
        <CardContent>
          <div v-if="setting.valueType === 'boolean'" class="flex items-center justify-between">
            <span class="text-sm text-muted-foreground">{{ setting.key }}</span>
            <Switch
              :model-value="boolValue(setting.value)"
              @update:model-value="updateBool(setting, Boolean($event))"
            />
          </div>
          <Input
            v-else
            v-model="setting.value"
            :type="setting.valueType === 'number' ? 'number' : 'text'"
          />
        </CardContent>
      </Card>
    </div>
  </div>
</template>
