<script lang="ts" setup>
import { KeyRound, Mail, ShieldCheck } from 'lucide-vue-next';
import SecurityPagePasswordForm from '@/components/SecurityPagePasswordForm.vue';
import SecurityPageEmail from '@/components/SecurityPageEmail.vue';
import SecurityPageTwoFactor from '@/components/SecurityPageTwoFactor.vue';
import SecurityPagePasskeys from '@/components/SecurityPagePasskeys.vue';
import SecurityPageGitHub from '@/components/SecurityPageGitHub.vue';
import SecurityPageDangerZone from '@/components/SecurityPageDangerZone.vue';
import { ref, onUnmounted } from 'vue';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
import { Button } from '@/components/ui/button';
import { usePreferenceStore } from '@/stores/user';
import { toast } from 'vue-sonner';

const { t } = useAppLocale();
const localePath = useLocalePath();
const preferenceStore = usePreferenceStore();
const app = useNuxtApp();
const queue = authQueueFor(app);
let disposed = false;
let ownerRevision = queue.revision;
const expired = ref(queue.isIdentityChanging);
const changing = ref(queue.isIdentityChanging);
const contentRevision = ref(0);
const stopObserving = queue.subscribe(() => {
  changing.value = queue.isIdentityChanging;
  if (queue.revision !== ownerRevision) expired.value = true;
});
onUnmounted(() => { disposed = true; stopObserving(); });
function reopen(): void {
  if (disposed || changing.value) return;
  ownerRevision = queue.revision;
  contentRevision.value++;
  expired.value = false;
}
async function finishSessionClear(result: {revision: number; ok: boolean}): Promise<void> {
  if (disposed || !preferenceStore.isAuthCurrent(result.revision)) return;
  if (!result.ok) { toast.error(t('account.security.sessionActionFailed')); return; }
  try { await app.runWithContext(() => navigateTo(localePath('/auth/login'))); }
  catch { if (!disposed && preferenceStore.isAuthCurrent(result.revision)) toast.error(t('account.security.sessionActionFailed')); }
}
</script>

<template>
  <div v-if="expired" key="session-expired" role="status" class="grid gap-3 rounded-xl border border-border/60 bg-card p-5">
    <p>{{ t('account.security.sessionChanged') }}</p>
    <Button :disabled="changing" class="w-fit" @click="reopen">
      {{ t('account.security.reopen') }}
    </Button>
  </div>
  <div v-else :key="'security-' + contentRevision" class="space-y-6">
    <section
      class="rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="mb-5 flex items-start gap-3">
        <div
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
        >
          <KeyRound class="h-4 w-4" />
        </div>
        <div class="min-w-0 space-y-1">
          <h2 class="text-base font-semibold tracking-tight">
            {{ t('account.security.securityPage.password.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.security.securityPage.password.description') }}
          </p>
        </div>
      </header>
      <SecurityPagePasswordForm :on-session-cleared="finishSessionClear" />
    </section>

    <section
      class="rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="mb-5 flex items-start gap-3">
        <div
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
        >
          <ShieldCheck class="h-4 w-4" />
        </div>
        <div class="min-w-0 space-y-1">
          <h2 class="text-base font-semibold tracking-tight">
            {{ t('account.security.twoFactor.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.security.twoFactor.description') }}
          </p>
        </div>
      </header>
      <SecurityPageTwoFactor />
    </section>

    <SecurityPagePasskeys />
    <SecurityPageGitHub />

    <section
      class="rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="mb-5 flex items-start gap-3">
        <div
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
        >
          <Mail class="h-4 w-4" />
        </div>
        <div class="min-w-0 space-y-1">
          <h2 class="text-base font-semibold tracking-tight">
            {{ t('account.security.securityPage.email.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.security.securityPage.email.description') }}
          </p>
        </div>
      </header>
      <SecurityPageEmail :on-session-cleared="finishSessionClear" />
    </section>

    <SecurityPageDangerZone />
  </div>
</template>
