<script setup lang="ts">
import { onMounted, ref } from 'vue';
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

const invites = ref<GroupInviteView[]>([]);
const isRefreshing = ref(false);
const { t } = useAppLocale();

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

async function refreshInvites(): Promise<void> {
  isRefreshing.value = true;
  try {
    invites.value = await listMyGroupInvites();
  } catch (error) {
    invites.value = [];
    toast.error(t('groups.feedback.loadInvitesFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    isRefreshing.value = false;
  }
}

async function handleAccept(id: number): Promise<void> {
  try {
    await respondGroupInvite(id, true);
    invites.value = invites.value.filter(
      invite => invite.id !== id
    );
    toast.success(t('groups.feedback.inviteAccepted'));
  } catch (error) {
    toast.error(t('groups.feedback.inviteAcceptFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function handleReject(id: number): Promise<void> {
  try {
    await respondGroupInvite(id, false);
    invites.value = invites.value.filter(
      invite => invite.id !== id
    );
    toast.info(t('groups.feedback.inviteRejected'));
  } catch (error) {
    toast.error(t('groups.feedback.inviteRejectFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function handleRefresh(): Promise<void> {
  await refreshInvites();
  toast.success(t('groups.feedback.refreshed'));
}

onMounted(() => {
  void refreshInvites();
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
        {{ t('groups.invites.pendingCount', { count: invites.length }) }}
      </span>
      <Button
        variant="outline"
        class="h-9 w-full rounded-md shadow-xs sm:w-auto"
        :disabled="isRefreshing"
        @click="handleRefresh"
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

    <div
      v-if="invites.length === 0"
      class="flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-border/60 bg-muted/10 py-16 text-center"
    >
      <span
        class="flex h-14 w-14 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Inbox class="h-6 w-6 text-muted-foreground" />
      </span>
      <div class="grid gap-1">
        <h3 class="text-sm font-semibold tracking-tight">
          {{ t('groups.invites.emptyTitle') }}
        </h3>
        <p class="max-w-sm text-xs text-muted-foreground">
          {{ t('groups.invites.emptyDescription') }}
        </p>
      </div>
    </div>

    <div v-else class="grid gap-3">
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
              @click="handleReject(invite.id)"
            >
              <XCircle class="h-3.5 w-3.5" />
              {{ t('groups.invites.reject') }}
            </Button>
            <Button
              class="h-8 rounded-md shadow-xs"
              @click="handleAccept(invite.id)"
            >
              <CheckCircle class="h-3.5 w-3.5" />
              {{ t('groups.invites.accept') }}
            </Button>
          </div>
        </div>
      </article>
    </div>
  </div>
</template>
