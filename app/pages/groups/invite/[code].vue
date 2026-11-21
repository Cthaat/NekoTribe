<script setup lang="ts">
import { Button } from '@/components/ui/button';
import { v2GetInvitePreview, v2JoinGroup } from '@/api/v2/groups';
import { normalizeGroupInviteCode } from '@/utils/group-invite';
import type { V2InviteCodeData } from '@/types/v2';
import { usePreferenceStore } from '@/stores/user';

const { t } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();
const session = usePreferenceStore();
const preview = shallowRef<V2InviteCodeData | null>(null);
const loading = ref(true);
const joining = ref(false);
const error = ref('');
const status = ref('');
let request = 0;
let destroyed = false;
const code = computed(() => normalizeGroupInviteCode(route.params.code));

useHead({
  title: () => t('groups.invitePreview.title'),
  meta: [{ name: 'referrer', content: 'no-referrer' }, { name: 'robots', content: 'noindex' }]
});

function isCurrent(revision: number, sequence: number) {
  return !destroyed && sequence === request && session.isAuthCurrent(revision);
}

async function load() {
  const sequence = ++request;
  const revision = session.authRevision();
  preview.value = null;
  status.value = '';
  error.value = '';
  joining.value = false;
  loading.value = true;
  if (!code.value) {
    loading.value = false;
    error.value = t('groups.invitePreview.invalid');
    return;
  }
  try {
    const result = await v2GetInvitePreview(code.value);
    if (!isCurrent(revision, sequence)) return;
    if (!result.is_valid || !Number.isSafeInteger(result.group?.group_id) || result.group.group_id < 1) {
      error.value = t('groups.invitePreview.invalid');
      return;
    }
    preview.value = result;
    status.value = result.group.membership.status ?? '';
  } catch (cause) {
    if (isCurrent(revision, sequence)) {
      error.value = cause instanceof Error ? cause.message : t('groups.invitePreview.invalid');
    }
  } finally {
    if (isCurrent(revision, sequence)) loading.value = false;
  }
}

async function join() {
  const invite = preview.value;
  const inviteCode = code.value;
  if (!invite || !inviteCode || status.value || joining.value) return;
  const sequence = request;
  const revision = session.authRevision();
  joining.value = true;
  error.value = '';
  try {
    const result = await v2JoinGroup(invite.group.group_id, { invite_code: inviteCode });
    if (isCurrent(revision, sequence)) status.value = result.status;
  } catch (cause) {
    if (isCurrent(revision, sequence)) {
      error.value = cause instanceof Error ? cause.message : t('groups.invitePreview.invalid');
    }
  } finally {
    if (isCurrent(revision, sequence)) joining.value = false;
  }
}

if (import.meta.client) watch([code, () => session.preferences.user.id], () => void load(), { immediate: true });
onBeforeUnmount(() => { destroyed = true; });
</script>

<template>
  <section class="mx-auto max-w-xl rounded-xl border bg-card p-5 sm:p-7" :aria-busy="loading || joining">
    <h1 class="text-xl font-semibold">{{ t('groups.invitePreview.title') }}</h1>
    <p v-if="loading" class="mt-3 text-sm text-muted-foreground" role="status">
      {{ t('groups.invitePreview.loading') }}
    </p>
    <div v-if="preview" class="mt-4 space-y-3">
      <h2 class="break-words text-lg font-semibold">{{ preview.group.name }}</h2>
      <p v-if="preview.group.description" class="whitespace-pre-line break-words text-sm text-muted-foreground">
        {{ preview.group.description }}
      </p>
      <p class="text-sm">
        {{ t('groups.invitePreview.from', { name: preview.inviter.display_name || preview.inviter.username }) }}
      </p>
      <blockquote v-if="preview.message" class="break-words border-s pl-3 text-sm">
        {{ preview.message }}
      </blockquote>
      <p v-if="status" role="status" class="text-sm">
        {{ t(status === 'pending' ? 'groups.invitePreview.pending' : status === 'banned' ? 'groups.invitePreview.unavailable' : 'groups.invitePreview.joined') }}
      </p>
      <Button v-else type="button" :disabled="joining" @click="join">
        {{ t('groups.invitePreview.join') }}
      </Button>
    </div>
    <p v-if="error" class="mt-4 break-words text-sm text-destructive" role="alert">{{ error }}</p>
    <div class="mt-5 flex flex-wrap gap-3">
      <Button v-if="error && !preview && code && !loading" type="button" variant="outline" @click="load">
        {{ t('groups.invitePreview.retry') }}
      </Button>
      <NuxtLink :to="localePath(status === 'active' || status === 'muted' ? '/groups/my' : '/groups/discover')" class="self-center text-sm text-primary underline underline-offset-4">
        {{ t(status === 'active' || status === 'muted' ? 'groups.tabs.my' : 'groups.tabs.discover') }}
      </NuxtLink>
    </div>
  </section>
</template>
