<script setup lang="ts">
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { authQueueFor } from '@/services/auth-request-queue';
import { getUserProvider, putUserProvider, removeUserProvider, validProviderKey, validProviderModel, verifyUserProvider } from '@/api/v2/ai-user-provider';
import type { UserProviderPreset, UserProviderView } from '@/api/v2/ai-user-provider';

const { t } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const view = ref<UserProviderView | null>(null);
const preset = ref<UserProviderPreset>('default');
const model = ref('');
const apiKey = ref('');
const enabled = ref(true);
const pending = ref<'loading'|'saving'|'testing'|'removing'|null>(null);
const state = ref<'saved'|'verified'|'removed'|'failed'|'changed' | null>(null);
const confirmRemove = ref(false);
let request: AbortController | null = null;
let unsubscribe: (()=>void) | undefined;

const saved = computed(()=>view.value?.config);
const selectedUrl = computed(()=>view.value?.presets.find(item=>item.id===preset.value)?.base_url);
const needsKey = computed(()=>!saved.value || saved.value.preset!==preset.value || saved.value.reconnect_required);
const canSave = computed(()=>!!selectedUrl.value && validProviderModel(model.value.trim()) &&
  (apiKey.value ? validProviderKey(apiKey.value) : !needsKey.value));

function apply(next: UserProviderView) {
  view.value = next;
  preset.value = next.presets.some(item=>item.id===next.config?.preset) && next.config ? next.config.preset : 'default';
  model.value = next.config?.model ?? '';
  enabled.value = next.config?.enabled ?? true;
}

async function run(operation: NonNullable<typeof pending.value>, task: (signal:AbortSignal)=>Promise<()=>void>) {
  if (request || auth.isIdentityChanging) return;
  const current = new AbortController();
  const identity = auth.revision;
  request = current;
  pending.value = operation;
  state.value = null;
  function active() { return request===current && !current.signal.aborted && identity===auth.revision; }
  try {
    const update = await app.runWithContext(()=>task(current.signal));
    if (active()) update();
  } catch (error) {
    if (active()) {
      const status = (error as {statusCode?:number;status?:number} | null)?.statusCode ??
        (error as {status?:number} | null)?.status;
      state.value = status === 409 ? 'changed' : 'failed';
    }
  } finally {
    if (request===current) {
      request = null;
      pending.value = null;
    }
  }
}
const load = () => run('loading',async signal=>{
  const next = await getUserProvider(signal);
  return () => apply(next);
});
function save() {
  if (!canSave.value || pending.value || auth.isIdentityChanging) return;
  const credential = apiKey.value;
  apiKey.value = '';
  const input = {preset:preset.value,model:model.value.trim(),enabled:enabled.value,
    ...(credential ? {api_key:credential} : {})};
  return run('saving',async signal=>{
    const next = await putUserProvider(input,signal);
    return ()=>{apply(next);state.value='saved';};
  });
}
const verify = () => run('testing',async signal=>{
  await verifyUserProvider(signal);
  return ()=>{state.value='verified';};
});
const remove = () => run('removing',async signal=>{
  await removeUserProvider(signal);
  return ()=>{
    if (view.value) apply({...view.value,config:null});
    apiKey.value = '';
    confirmRemove.value = false;
    state.value = 'removed';
  };
});
function clear() {
  request?.abort();
  request = null;
  pending.value = null;
  view.value = null;
  apiKey.value = '';
  model.value = '';
  state.value = null;
  confirmRemove.value = false;
}
watch(preset,()=>{apiKey.value='';});
onMounted(()=>{
  unsubscribe = auth.subscribe(()=>{
    clear();
    if (!auth.isIdentityChanging) void load();
  });
  void load();
});
onBeforeUnmount(()=>{unsubscribe?.();clear();});
</script>

<template>
  <section class="mx-auto max-w-2xl space-y-5 p-4">
    <header class="space-y-1">
      <h1 class="text-xl font-semibold">{{ t('aiUserProvider.title') }}</h1>
      <p class="text-sm text-muted-foreground">{{ t('aiUserProvider.description') }}</p>
    </header>
    <p v-if="pending === 'loading'" role="status" class="text-sm text-muted-foreground">{{ t('aiUserProvider.loading') }}</p>
    <p v-else-if="view && !view.setup_available" class="text-sm text-muted-foreground">{{ t('aiUserProvider.unavailable') }}</p>
    <form v-if="view?.setup_available" class="grid gap-4 rounded-xl border p-4" @submit.prevent="save">
      <label class="grid gap-1.5 text-sm">
        {{ t('aiUserProvider.endpoint') }}
        <select v-model="preset" :disabled="!!pending" class="rounded-md border bg-background px-3 py-2">
          <option v-for="option in view.presets" :key="option.id" :value="option.id">
            {{ t(`aiUserProvider.preset.${option.id}`) }}
          </option>
        </select>
        <span v-if="selectedUrl" class="break-all text-xs text-muted-foreground">{{ selectedUrl }}</span>
      </label>
      <label class="grid gap-1.5 text-sm">
        {{ t('aiUserProvider.model') }}
        <Input v-model="model" :disabled="!!pending" maxlength="128" autocomplete="off" required />
      </label>
      <label class="grid gap-1.5 text-sm">
        {{ t('aiUserProvider.key') }}
        <Input v-model="apiKey" :disabled="!!pending" type="password" autocomplete="new-password" maxlength="512" />
        <span class="text-xs text-muted-foreground">{{ t(needsKey ? 'aiUserProvider.keyRequired' : 'aiUserProvider.keepKey') }}</span>
      </label>
      <label class="flex items-center gap-2 text-sm">
        <input v-model="enabled" type="checkbox" :disabled="!!pending">
        {{ t('aiUserProvider.enable') }}
      </label>
      <p v-if="saved?.reconnect_required" class="text-sm text-destructive">{{ t('aiUserProvider.changed') }}</p>
      <div class="flex flex-wrap gap-2">
        <Button type="submit" :disabled="!!pending || !canSave">{{ t('aiUserProvider.save') }}</Button>
        <Button v-if="saved" type="button" variant="outline" :disabled="!!pending || saved.reconnect_required" @click="verify">
          {{ t('aiUserProvider.test') }}
        </Button>
        <Button v-if="saved && !confirmRemove" type="button" variant="outline" :disabled="!!pending" @click="confirmRemove=true">
          {{ t('aiUserProvider.remove') }}
        </Button>
      </div>
      <div v-if="confirmRemove" class="flex flex-wrap items-center gap-2 rounded-md border p-2 text-sm">
        <span>{{ t('aiUserProvider.removePrompt') }}</span>
        <Button type="button" variant="destructive" size="sm" :disabled="!!pending" @click="remove">
          {{ t('aiUserProvider.remove') }}
        </Button>
        <Button type="button" variant="ghost" size="sm" @click="confirmRemove=false">{{ t('aiUserProvider.cancel') }}</Button>
      </div>
    </form>
    <p v-if="state" role="status" class="text-sm" :class="state==='failed'||state==='changed' ? 'text-destructive' : 'text-muted-foreground'">
      {{ t(`aiUserProvider.${state}`) }}
    </p>
    <Button v-if="state === 'failed' && !view" type="button" variant="outline" @click="load">{{ t('aiUserProvider.retry') }}</Button>
  </section>
</template>
