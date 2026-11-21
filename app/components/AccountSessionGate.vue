<script setup lang="ts">
import { ref, onUnmounted } from 'vue';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
import { Button } from '@/components/ui/button';

const { t } = useAppLocale();
const queue = authQueueFor(useNuxtApp());
let ownerRevision = queue.revision;
let disposed = false;
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
</script>

<template>
  <div v-if="expired" key="preferences-expired" role="status" class="grid gap-3 rounded-xl border border-border/60 bg-card p-5">
    <p>{{ t('account.settings.sessionChanged') }}</p>
    <Button :disabled="changing" class="w-fit" @click="reopen">{{ t('account.settings.reopen') }}</Button>
  </div>
  <div v-else :key="'preferences-' + contentRevision"><slot /></div>
</template>
