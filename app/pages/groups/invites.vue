<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';
import { toast } from 'vue-sonner';
import {
  Clock,
  CheckCircle,
  XCircle,
  Users,
  RefreshCw,
  Inbox
} from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import {
  listMyGroupInvites,
  respondGroupInvite
} from '@/services/groups';
import type { GroupInviteView } from '@/types/groups';
import { authQueueFor } from '@/services/auth-request-queue';
import { matchesGroupInviteResponse } from '@/utils/group-invite';
import { notificationTargetId } from '@/utils/post-notification-target';

definePageMeta({ key: route => route.fullPath });

const inviteId = notificationTargetId(useRoute().query.invite) ?? undefined;

const invites = ref<GroupInviteView[]>([]);
const isRefreshing = ref(false);
const responding = ref(false);
const hasNext = ref(false);
const total = ref(0);
const failed = ref(false);
const expired = ref(false);
const acceptedGroup = ref<GroupInviteView['group'] | null>(null);
let page = 0;
let readRequest: AbortController | undefined;
let writeRequest: AbortController | undefined;
let unsubscribe: (() => void) | undefined;
const app = useNuxtApp();
const auth = authQueueFor(app);
const { t } = useAppLocale();
const localePath = useLocalePath();

function formatTime(dateStr: string): string {
  const date = new Date(dateStr);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const hours = Math.floor(diff / (1000 * 60 * 60));

  if (hours < 1) {
    const minutes = Math.floor(diff / (1000 * 60));
    return t('time.minutesAgo', { count: Math.max(minutes, 0) });
  }
  if (hours < 24) return t('time.hoursAgo', { count: hours });
  return t('time.daysAgo', { count: Math.floor(hours / 24) });
}

function getRemainingTime(expiresAt: string): string {
  const expires = new Date(expiresAt);
  const now = new Date();
  const diff = expires.getTime() - now.getTime();

  if (diff <= 0) return t('groups.invites.expired');

  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  const hours = Math.floor(
    (diff % (1000 * 60 * 60 * 24)) /
      (1000 * 60 * 60)
  );

  if (days > 0) {
    return t('groups.invites.expiresInDays', {
      days,
      hours
    });
  }
  return t('groups.invites.expiresInHours', { hours });
}

async function refreshInvites(append = false): Promise<void> {
  if (expired.value || auth.isIdentityChanging || isRefreshing.value ||
      (append && !hasNext.value)) return;
  const request = new AbortController();
  readRequest = request;
  const revision = auth.revision;
  const current = () => readRequest === request && revision === auth.revision;
  const next = append ? page + 1 : 1;
  isRefreshing.value = true;
  failed.value = false;
  if (!append) {
    invites.value = [];
    hasNext.value = false;
    total.value = 0;
    page = 0;
  }
  try {
    const result = await app.runWithContext(() => listMyGroupInvites(next, request.signal, inviteId));
    if (!current()) return;
    const entries = new Map(invites.value.map(invite => [invite.id, invite]));
    for (const invite of result.items) entries.set(invite.id, invite);
    invites.value = [...entries.values()];
    hasNext.value = result.hasNext;
    total.value = result.total;
    page = next;
  } catch {
    if (current()) failed.value = true;
  } finally {
    if (current()) isRefreshing.value = false;
  }
}

async function handleResponse(invite: GroupInviteView, accept: boolean): Promise<void> {
  if (expired.value || auth.isIdentityChanging || responding.value || isRefreshing.value) return;
  if (!Number.isSafeInteger(invite.id) || invite.id <= 0 ||
      !Number.isSafeInteger(invite.group.id) || invite.group.id <= 0) return;
  const request = new AbortController();
  writeRequest = request;
  const revision = auth.revision;
  const current = () => writeRequest === request && revision === auth.revision;
  responding.value = true;
  try {
    const receipt = await app.runWithContext(() => respondGroupInvite(invite.id, accept, request.signal));
    if (!current()) return;
    if (!matchesGroupInviteResponse(receipt, invite.id, invite.group.id, accept)) throw Error('Invalid invite response');
    if (accept) {
      acceptedGroup.value = invite.group;
      toast.success(t('groups.feedback.inviteAccepted'));
    } else {
      toast.info(t('groups.feedback.inviteRejected'));
    }
  } catch {
    if (current()) toast.error(t('groups.feedback.inviteResponseUnknown'));
  } finally {
    if (current()) {
      await refreshInvites();
      if (current()) responding.value = false;
    }
  }
}

function clearRequests() {
  readRequest?.abort();
  writeRequest?.abort();
  readRequest = writeRequest = undefined;
}

onMounted(() => {
  unsubscribe = auth.subscribe(() => {
    clearRequests();
    expired.value = true;
    invites.value = [];
    acceptedGroup.value = null;
    total.value = 0;
    hasNext.value = responding.value = isRefreshing.value = failed.value = false;
  });
  expired.value = auth.isIdentityChanging;
  void refreshInvites();
});
onBeforeUnmount(() => {
  unsubscribe?.();
  clearRequests();
});
</script>

<template>
  <div class="grid gap-4">
    <div
      class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
    >
      <span
        class="inline-flex items-center gap-1.5 rounded-full border border-border/60 bg-muted/40 px-2.5 py-1 text-xs font-medium text-muted-foreground"
      >
        <Inbox class="h-3 w-3" />
        {{ t('groups.invites.pendingCount', { count: total }) }}
      </span>
      <Button v-if="inviteId !== undefined" as-child variant="ghost" size="sm">
        <NuxtLink :to="localePath('/groups/invites')">{{ t('groups.invites.viewAll') }}</NuxtLink>
      </Button>
      <Button
        variant="outline"
        class="h-9 w-full rounded-md shadow-xs sm:w-auto"
        :disabled="isRefreshing || responding || expired"
        @click="refreshInvites()"
      >
        <RefreshCw
          :class="[
            'h-3.5 w-3.5',
            { 'animate-spin': isRefreshing }
          ]"
        />
        {{ t('common.refresh') }}
      </Button>
    </div>

    <div v-if="acceptedGroup" class="flex flex-wrap items-center justify-between gap-2 rounded-lg border px-4 py-3">
      <span class="break-words text-sm" role="status">{{ acceptedGroup.name }}</span>
      <Button as-child variant="outline" size="sm">
        <NuxtLink :to="localePath({ path: '/groups/posts', query: { group: String(acceptedGroup.id) } })">
          {{ t('groups.invites.openGroup') }}
        </NuxtLink>
      </Button>
    </div>
    <p v-if="expired" role="status">{{ t('visibility.sessionChanged') }}</p>
    <p v-else-if="failed" role="alert">{{ t('groups.feedback.loadInvitesFailed') }}</p>
    <div
      v-else-if="!isRefreshing && invites.length === 0 && (inviteId === undefined || !acceptedGroup)"
      class="flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-border/60 bg-muted/10 py-16 text-center"
    >
      <span
        class="flex h-14 w-14 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Inbox class="h-6 w-6 text-muted-foreground" />
      </span>
      <div class="grid gap-1">
        <h3 class="text-sm font-semibold tracking-tight">
          {{ t(inviteId === undefined ? 'groups.invites.emptyTitle' : 'groups.invites.unavailable') }}
        </h3>
        <p v-if="inviteId === undefined" class="max-w-sm text-xs text-muted-foreground">
          {{ t('groups.invites.emptyDescription') }}
        </p>
      </div>
    </div>

    <div v-if="invites.length" class="grid gap-3">
      <article
        v-for="invite in invites"
        :key="invite.id"
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none transition-all hover:border-border hover:shadow-md"
      >
        <div class="flex items-start gap-3 sm:gap-4">
          <Avatar class="h-12 w-12 shrink-0 ring-1 ring-border sm:h-14 sm:w-14">
            <AvatarImage
              :src="invite.group.avatar"
              :alt="invite.group.name"
            />
            <AvatarFallback
              class="bg-primary/10 text-base font-semibold text-primary"
            >
              {{ invite.group.name.charAt(0) }}
            </AvatarFallback>
          </Avatar>

          <div class="min-w-0 flex-1 grid gap-2">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <h3 class="min-w-0 truncate text-base font-semibold tracking-tight">
                {{ invite.group.name }}
              </h3>
              <span
                class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground"
              >
                <Users class="h-3 w-3" />
                <span class="tabular-nums">{{ invite.group.memberCount }}</span>
              </span>
            </div>
            <p class="line-clamp-2 text-sm text-muted-foreground">
              {{ invite.group.description }}
            </p>

            <div class="flex items-center gap-2 text-xs">
              <Avatar class="h-6 w-6 ring-1 ring-border">
                <AvatarImage :src="invite.inviter.avatar" />
                <AvatarFallback
                  class="bg-primary/10 text-[10px] font-semibold text-primary"
                >
                  {{ invite.inviter.nickname.charAt(0) }}
                </AvatarFallback>
              </Avatar>
              <span class="text-foreground">
                <span class="font-medium">{{ invite.inviter.nickname }}</span>
                <span class="text-muted-foreground">
                  {{ t('groups.invites.invitedYou') }}
                </span>
              </span>
            </div>

            <blockquote
              v-if="invite.message"
              class="rounded-lg border-l-2 border-primary/40 bg-muted/30 px-3 py-2 text-sm italic text-muted-foreground"
            >
              {{ invite.message }}
            </blockquote>
          </div>
        </div>

        <div
          class="flex flex-col gap-3 border-t border-border/60 pt-3 sm:flex-row sm:items-center sm:justify-between"
        >
          <div
            class="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-[11px] text-muted-foreground"
          >
            <span class="inline-flex items-center gap-1">
              <Clock class="h-3 w-3" />
              {{ formatTime(invite.createdAt) }}
            </span>
            <span
              v-if="invite.expiresAt"
              class="inline-flex items-center gap-1 rounded-full border border-amber-200/60 bg-amber-100/60 px-2 py-0.5 font-medium text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300"
            >
              <Clock class="h-3 w-3" />
              {{ getRemainingTime(invite.expiresAt) }}
            </span>
          </div>

          <div
            class="grid w-full grid-cols-2 gap-2 sm:flex sm:w-auto sm:items-center"
          >
            <Button
              variant="outline"
              class="h-8 rounded-md shadow-xs"
              :disabled="responding || isRefreshing"
              @click="handleResponse(invite, false)"
            >
              <XCircle class="h-3.5 w-3.5" />
              {{ t('groups.invites.reject') }}
            </Button>
            <Button
              class="h-8 rounded-md shadow-xs"
              :disabled="responding || isRefreshing"
              @click="handleResponse(invite, true)"
            >
              <CheckCircle class="h-3.5 w-3.5" />
              {{ t('groups.invites.accept') }}
            </Button>
          </div>
        </div>
      </article>
    </div>
    <Button v-if="hasNext" variant="outline" class="justify-self-center"
      :disabled="responding || isRefreshing" @click="refreshInvites(true)">
      {{ t(failed ? 'common.retry' : 'common.loadMore') }}
    </Button>
  </div>
</template>
