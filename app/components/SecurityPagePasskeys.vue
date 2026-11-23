<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue';
import { Fingerprint } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { cancelPasskeyPrompt, deletePasskey, listPasskeys, passkeyCancelled, registerPasskey, supportsPasskeys } from '@/api/v2/passkeys';
import type { PasskeySummary } from '@/api/v2/passkeys';
import { authQueueFor } from '@/services/auth-request-queue';

const { t, locale } = useAppLocale();
const app = useNuxtApp();
const identity = authQueueFor(app);
const revision = identity.revision;
const items = ref<PasskeySummary[]>([]);
const label = ref('');
const busy = ref(false);
const supported = ref(false);
const initialized = ref(false);
const status = ref('');
let disposed = false;
let enrolling = false;
const current = () => !disposed && !identity.isIdentityChanging && identity.revision === revision;

function errorStatus(error: unknown): number | undefined {
  if (error && typeof error === 'object' && 'statusCode' in error && typeof error.statusCode === 'number') return error.statusCode;
}

async function refresh() {
  if (!current() || busy.value) return;
  busy.value = true;
  status.value = '';
  try {
    const next = await app.runWithContext(listPasskeys);
    if (!current()) return;
    items.value = next;
    initialized.value = true;
  } catch (error) {
    if (current()) status.value = errorStatus(error) === 503 ? 'passkeys.unavailable' : 'passkeys.loadFailed';
  } finally { if (current()) busy.value = false; }
}

async function add() {
  if (!current() || !supported.value || busy.value || Array.from(label.value.trim()).length > 80) return;
  busy.value = true;
  enrolling = true;
  status.value = '';
  try {
    const item = await app.runWithContext(() => registerPasskey(label.value.trim(), current));
    if (!current()) return;
    items.value = [item, ...items.value.filter(entry => entry.credential_id !== item.credential_id)];
    label.value = '';
    status.value = 'passkeys.added';
  } catch (error) {
    if (!current() || passkeyCancelled(error)) return;
    status.value = errorStatus(error) === 503 ? 'passkeys.unavailable' : 'passkeys.addFailed';
  } finally { enrolling = false; if (current()) busy.value = false; }
}

async function remove(item: PasskeySummary) {
  if (!current() || busy.value || !window.confirm(t('passkeys.confirmRemove', { label: item.label }))) return;
  busy.value = true;
  status.value = '';
  try {
    await app.runWithContext(() => deletePasskey(item.credential_id));
    if (!current()) return;
    items.value = items.value.filter(entry => entry.credential_id !== item.credential_id);
    status.value = 'passkeys.removed';
  } catch (error) {
    if (current()) status.value = errorStatus(error) === 409 ? 'passkeys.keepMethod' : 'passkeys.removeFailed';
  } finally { if (current()) busy.value = false; }
}

function dateLabel(value: string): string {
  return new Date(value).toLocaleDateString(locale.value);
}

onMounted(() => { supported.value = supportsPasskeys(); void refresh(); });
onUnmounted(() => { disposed = true; if (enrolling) cancelPasskeyPrompt(); });
</script>

<template>
  <section class="space-y-4 rounded-xl border border-border/60 bg-card p-5 sm:p-6" :aria-busy="busy">
    <header class="flex items-start gap-3">
      <div class="flex size-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary">
        <Fingerprint class="size-4" aria-hidden="true" />
      </div>
      <div class="space-y-1">
        <h2 class="text-base font-semibold tracking-tight">{{ t('passkeys.title') }}</h2>
        <p class="text-xs leading-relaxed text-muted-foreground">{{ t('passkeys.description') }}</p>
      </div>
    </header>
    <ul v-if="items.length" class="divide-y divide-border rounded-lg border border-border/60">
      <li v-for="item in items" :key="item.credential_id" class="flex items-center justify-between gap-3 px-3 py-2">
        <div class="min-w-0">
          <p class="break-words text-sm font-medium">{{ item.label }}</p>
          <p class="text-xs text-muted-foreground">
            {{ item.last_used_at ? t('passkeys.lastUsed', { date: dateLabel(item.last_used_at) }) : t('passkeys.created', { date: dateLabel(item.created_at) }) }}
          </p>
        </div>
        <Button type="button" variant="ghost" size="sm" :disabled="busy" @click="remove(item)">
          {{ t('passkeys.remove') }}
        </Button>
      </li>
    </ul>
    <p v-else-if="initialized" class="text-sm text-muted-foreground">{{ t('passkeys.empty') }}</p>
    <form v-if="supported && initialized" class="flex flex-wrap gap-2" @submit.prevent="add">
      <Input
        v-model="label" :aria-label="t('passkeys.label')" :placeholder="t('passkeys.label')"
        maxlength="160" class="min-w-32 flex-1" :disabled="busy" />
      <Button type="submit" :disabled="busy || Array.from(label.trim()).length > 80">
        {{ t('passkeys.add') }}
      </Button>
    </form>
    <Button v-else-if="!initialized && !busy && status" type="button" variant="outline" size="sm" @click="refresh">
      {{ t('common.retry') }}
    </Button>
    <p v-else-if="!supported && initialized" class="text-xs text-muted-foreground">{{ t('passkeys.unsupported') }}</p>
    <p v-if="status" role="status" class="text-sm text-muted-foreground">{{ t(status) }}</p>
  </section>
</template>
