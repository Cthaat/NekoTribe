<script setup lang="ts">
import { onMounted, onUnmounted, ref, shallowRef } from 'vue';
import { Github } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { bindGitHub, getGitHubLink, openGitHubWindow, unlinkGitHub } from '@/api/v2/github-oauth';
import type { GitHubLink } from '@/api/v2/github-oauth';
import { authQueueFor } from '@/services/auth-request-queue';

const { t } = useAppLocale();
const app = useNuxtApp();
const queue = authQueueFor(app);
const revision = queue.revision;
const loaded = ref(false);
const busy = ref(false);
const feedback = ref('');
const link = ref<GitHubLink | null>(null);
const binding = shallowRef<AbortController | null>(null);
let disposed = false;
const current = () => !disposed && !queue.isIdentityChanging && queue.revision === revision;

function statusOf(error: unknown): number | undefined {
  if (error && typeof error === 'object' && 'statusCode' in error && typeof error.statusCode === 'number') return error.statusCode;
}

async function refresh() {
  if (!current() || busy.value) return;
  busy.value = true;
  feedback.value = '';
  try {
    const result = await app.runWithContext(getGitHubLink);
    if (current()) { link.value = result; loaded.value = true; }
  } catch (error) {
    if (current()) feedback.value = statusOf(error) === 503 ? 'githubOAuth.unavailable' : 'githubOAuth.loadFailed';
  } finally { if (current()) busy.value = false; }
}

async function bind() {
  if (!current() || busy.value || !loaded.value || link.value) return;
  let popup: ReturnType<typeof openGitHubWindow>;
  try { popup = openGitHubWindow(); }
  catch { feedback.value = 'githubOAuth.popupBlocked'; return; }

  const controller = new AbortController();
  binding.value = controller;
  busy.value = true;
  feedback.value = '';
  try {
    const result = await app.runWithContext(() => bindGitHub({ current, signal: controller.signal, open: popup.open }));
    if (!current() || controller.signal.aborted) return;
    link.value = result;
    feedback.value = 'githubOAuth.linked';
  } catch (error) {
    if (!current() || controller.signal.aborted) return;
    feedback.value = statusOf(error) === 503 ? 'githubOAuth.unavailable' : 'githubOAuth.linkFailed';
  } finally { popup.close(); binding.value = null; if (current()) busy.value = false; }
}

async function unlink() {
  const account = link.value;
  if (!current() || busy.value || !account || !window.confirm(t('githubOAuth.confirmUnlink', { login: account.github_login }))) return;
  busy.value = true;
  feedback.value = '';
  try {
    await app.runWithContext(unlinkGitHub);
    if (!current()) return;
    link.value = null;
    feedback.value = 'githubOAuth.unlinked';
  } catch (error) {
    if (current()) feedback.value = statusOf(error) === 409 ? 'passkeys.keepMethod' : 'githubOAuth.unlinkFailed';
  } finally { if (current()) busy.value = false; }
}

onMounted(refresh);
onUnmounted(() => { disposed = true; binding.value?.abort(); });
</script>

<template>
  <section class="space-y-4 rounded-xl border border-border/60 bg-card p-5 sm:p-6" :aria-busy="busy">
    <header class="flex items-start gap-3">
      <div class="flex size-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary">
        <Github class="size-4" aria-hidden="true" />
      </div>
      <div class="space-y-1">
        <h2 class="text-base font-semibold tracking-tight">{{ t('githubOAuth.title') }}</h2>
        <p class="text-xs leading-relaxed text-muted-foreground">{{ t('githubOAuth.description') }}</p>
      </div>
    </header>
    <div v-if="link" class="flex items-center justify-between gap-3 rounded-lg border border-border/60 p-3">
      <span class="min-w-0 break-words text-sm font-medium">@{{ link.github_login }}</span>
      <Button variant="outline" type="button" size="sm" :disabled="busy" @click="unlink">{{ t('githubOAuth.unlink') }}</Button>
    </div>
    <div v-else-if="binding" class="flex items-center justify-between gap-3">
      <p class="text-sm text-muted-foreground" role="status">{{ t('githubOAuth.waiting') }}</p>
      <Button variant="outline" type="button" size="sm" @click="binding.abort()">{{ t('common.cancel') }}</Button>
    </div>
    <Button v-else-if="loaded" type="button" size="sm" :disabled="busy" @click="bind">{{ t('githubOAuth.link') }}</Button>
    <Button v-else-if="!busy && feedback" type="button" variant="outline" size="sm" @click="refresh">{{ t('common.retry') }}</Button>
    <p v-if="feedback" role="status" class="text-sm text-muted-foreground">{{ t(feedback) }}</p>
  </section>
</template>
