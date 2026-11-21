<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { useNuxtApp } from '#app';
import { Button } from '@/components/ui/button';
import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar';
import { authQueueFor } from '@/services/auth-request-queue';
import { listUserVisibility, setUserVisibility, type VisibilityKind, type VisibilityUser } from '@/api/v2/user-visibility';

const { t, locale } = useAppLocale();
const localePath = useLocalePath();
const queue = authQueueFor(useNuxtApp());
const owner = queue.revision;
const kind = ref<VisibilityKind>('blocks');
const users = ref<VisibilityUser[]>([]);
const page = ref(1);
const pageSize = 20;
const total = ref(0);
const loading = ref(false);
const removing = ref<number | null>(null);
const error = ref(false);
const removalError = ref(false);
const lastPage = computed(() => Math.max(1, Math.ceil(total.value / pageSize)));
let disposed = false;

const isCurrent = () => !disposed && !queue.isIdentityChanging && queue.revision === owner;
onUnmounted(() => { disposed = true; });

async function load(next: number): Promise<void> {
  if (loading.value || !isCurrent()) return;
  loading.value = true;
  error.value = false;
  try {
    let result = await listUserVisibility(kind.value, next, pageSize);
    if (!isCurrent()) return;
    const max = Math.max(1, Math.ceil((result.meta?.total ?? 0) / pageSize));
    if (next > max) {
      next = max;
      result = await listUserVisibility(kind.value, next, pageSize);
      if (!isCurrent()) return;
    }
    users.value = result.items;
    total.value = result.meta?.total ?? result.items.length;
    page.value = next;
  } catch {
    if (isCurrent()) error.value = true;
  } finally {
    if (isCurrent()) loading.value = false;
  }
}

function selectKind(next: VisibilityKind): void {
  if (!isCurrent() || loading.value || removing.value !== null || next === kind.value) return;
  kind.value = next;
  users.value = [];
  total.value = 0;
  page.value = 1;
  removalError.value = false;
  void load(1);
}

async function remove(target: number): Promise<void> {
  if (!isCurrent() || loading.value || removing.value !== null) return;
  removing.value = target;
  removalError.value = false;
  try {
    await setUserVisibility(kind.value, target, true);
    if (!isCurrent()) return;
    await load(page.value);
  } catch {
    if (isCurrent()) removalError.value = true;
  } finally {
    if (isCurrent()) removing.value = null;
  }
}

function muteDuration(expiry?: string | null): string {
  if (!expiry) return t('visibility.permanent');
  return t('visibility.until', { date: new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'medium', timeStyle: 'short'
  }).format(new Date(expiry)) });
}

onMounted(() => { void load(1); });
</script>

<template>
  <section class="grid gap-4 rounded-xl border border-border/60 bg-card p-4 sm:p-6">
    <h2 class="text-lg font-semibold">{{ t('visibility.title') }}</h2>
    <div class="flex flex-wrap gap-2" role="group" :aria-label="t('visibility.title')">
      <Button
        v-for="tab in (['blocks', 'mutes'] as const)"
        :key="tab"
        :variant="kind === tab ? 'secondary' : 'ghost'"
        :aria-pressed="kind === tab"
        :disabled="loading || removing !== null"
        size="sm"
        @click="selectKind(tab)"
      >{{ t(`visibility.${tab}`) }}</Button>
    </div>
    <p v-if="removalError" role="alert" class="text-sm text-destructive">{{ t('common.operationFailed') }}</p>
    <p v-if="loading" role="status" class="text-sm text-muted-foreground">{{ t('visibility.loading') }}</p>
    <div v-else-if="error" role="alert" class="flex flex-wrap items-center gap-2 text-sm">
      <span>{{ t('visibility.loadFailed') }}</span>
      <Button variant="outline" size="sm" @click="load(page)">{{ t('visibility.retry') }}</Button>
    </div>
    <p v-else-if="!users.length" class="text-sm text-muted-foreground">
      {{ t(kind === 'blocks' ? 'visibility.emptyBlocks' : 'visibility.emptyMutes') }}
    </p>
    <ul v-else class="divide-y divide-border">
      <li v-for="person in users" :key="person.user_id" class="flex flex-wrap items-center justify-between gap-2 py-3">
        <NuxtLink :to="localePath(`/user/${person.user_id}/profile`)" class="flex min-w-0 items-center gap-3 hover:underline">
          <Avatar class="h-9 w-9 shrink-0">
            <AvatarImage :src="person.avatar_url" alt="" />
            <AvatarFallback>{{ person.username.slice(0, 1) }}</AvatarFallback>
          </Avatar>
          <span class="grid min-w-0">
            <span class="truncate text-sm font-medium">{{ person.display_name || person.username }}</span>
            <span v-if="kind === 'mutes'" class="text-xs text-muted-foreground">{{ muteDuration(person.expires_at) }}</span>
          </span>
        </NuxtLink>
        <Button variant="outline" size="sm" :disabled="removing !== null"
          @click="remove(person.user_id)">
          {{ t(kind === 'blocks' ? 'visibility.unblock' : 'visibility.unmute') }}
        </Button>
      </li>
    </ul>
    <div v-if="lastPage > 1" class="flex flex-wrap items-center gap-2">
      <Button size="sm" variant="outline" :disabled="page <= 1 || loading || removing !== null" @click="load(page - 1)">{{ t('visibility.previous') }}</Button>
      <span class="text-sm tabular-nums">{{ page }} / {{ lastPage }}</span>
      <Button size="sm" variant="outline" :disabled="page >= lastPage || loading || removing !== null" @click="load(page + 1)">{{ t('visibility.next') }}</Button>
    </div>
  </section>
</template>
