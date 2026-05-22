<script setup lang="ts">
import { onMounted, ref, watch } from 'vue';
import {
  Ban,
  CheckCircle,
  Inbox,
  Loader2,
  RefreshCw,
  Search,
  ShieldAlert,
  Users as UsersIcon,
  VolumeX
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import {
  listModerationUsers,
  moderateUser
} from '@/services';
import type { ModerationUserVM } from '@/types/moderation';

const { t } = useAppLocale();

const users = ref<ModerationUserVM[]>([]);
const loading = ref(false);
const page = ref(1);
const hasNext = ref(false);
const pageSize = 20;
const filters = ref({
  q: '',
  status: 'all',
  sort: 'newest'
});

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

function statusPillClass(active: boolean): string {
  return active
    ? `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`
    : `${PILL_BASE} border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300`;
}

function restrictionPillClass(): string {
  return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
}

function initials(user: ModerationUserVM): string {
  return (user.name || user.username || '?').slice(0, 1).toUpperCase();
}

async function loadUsers(reset = true): Promise<void> {
  loading.value = true;
  try {
    const nextPage = reset ? 1 : page.value + 1;
    const result = await listModerationUsers({
      q: filters.value.q,
      status: filters.value.status,
      sort: filters.value.sort,
      page: nextPage,
      pageSize
    });
    users.value = reset
      ? result.items
      : [...users.value, ...result.items];
    page.value = result.page;
    hasNext.value = result.hasNext;
  } catch (error) {
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    loading.value = false;
  }
}

async function applyUserAction(
  user: ModerationUserVM,
  action: 'ban' | 'unban' | 'mute' | 'unmute'
): Promise<void> {
  try {
    const updated = await moderateUser(user.id, action, {
      reason: t('moderation.users.defaultReason'),
      durationHours: 24
    });
    const index = users.value.findIndex(item => item.id === user.id);
    if (index >= 0) users.value[index] = updated;
    toast.success(t('moderation.feedback.actionSuccess'));
  } catch (error) {
    toast.error(t('moderation.feedback.actionFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

watch(
  filters,
  () => {
    void loadUsers(true);
  },
  { deep: true }
);

onMounted(() => {
  void loadUsers(true);
});
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-3 rounded-xl border border-border/60 bg-card p-4 shadow-none sm:flex sm:flex-wrap sm:items-center"
    >
      <div class="relative min-w-0 sm:min-w-[220px] sm:flex-1">
        <Search
          class="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          v-model="filters.q"
          class="h-9 pl-9 shadow-xs"
          :placeholder="t('moderation.users.searchPlaceholder')"
        />
      </div>
      <Select v-model="filters.status">
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
          <SelectValue :placeholder="t('moderation.users.status')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">{{ t('moderation.status.all') }}</SelectItem>
          <SelectItem value="active">{{ t('moderation.users.active') }}</SelectItem>
          <SelectItem value="suspended">{{ t('moderation.users.suspended') }}</SelectItem>
          <SelectItem value="disabled">{{ t('moderation.users.disabled') }}</SelectItem>
          <SelectItem value="pending">{{ t('moderation.users.pending') }}</SelectItem>
        </SelectContent>
      </Select>
      <Select v-model="filters.sort">
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
          <SelectValue :placeholder="t('moderation.filters.sortPlaceholder')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="newest">{{ t('moderation.filters.sort.newest') }}</SelectItem>
          <SelectItem value="oldest">{{ t('moderation.filters.sort.oldest') }}</SelectItem>
          <SelectItem value="reports">{{ t('moderation.users.mostReported') }}</SelectItem>
        </SelectContent>
      </Select>
      <Button
        variant="outline"
        class="h-9 w-full rounded-md shadow-xs sm:ml-auto sm:w-auto"
        @click="loadUsers(true)"
      >
        <RefreshCw class="h-3.5 w-3.5" />
        {{ t('moderation.actions.refresh') }}
      </Button>
    </section>

    <div v-if="loading && users.length === 0" class="grid gap-3">
      <div
        v-for="item in 4"
        :key="item"
        class="rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <Skeleton class="h-24 rounded-lg" />
      </div>
    </div>

    <div
      v-else-if="users.length === 0"
      class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border/60 bg-muted/10 py-12 text-center"
    >
      <span
        class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Inbox class="h-5 w-5 text-muted-foreground" />
      </span>
      <p class="text-sm text-muted-foreground">
        {{ t('moderation.users.empty') }}
      </p>
    </div>

    <template v-else>
      <article
        v-for="user in users"
        :key="user.id"
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none transition-all hover:border-border hover:shadow-md"
      >
        <header class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex min-w-0 items-center gap-3">
            <Avatar class="h-11 w-11 shrink-0 ring-1 ring-border">
              <AvatarImage :src="user.avatarUrl" />
              <AvatarFallback
                class="bg-primary/10 text-sm font-semibold text-primary"
              >
                {{ initials(user) }}
              </AvatarFallback>
            </Avatar>
            <div class="min-w-0">
              <h3 class="flex min-w-0 items-center gap-2 text-base font-semibold tracking-tight">
                <span class="truncate">{{ user.name }}</span>
                <CheckCircle
                  v-if="user.verified"
                  class="h-4 w-4 shrink-0 text-primary"
                />
              </h3>
              <p class="mt-0.5 truncate text-xs text-muted-foreground">
                <span class="font-mono">@{{ user.username }}</span>
                <span class="mx-1">·</span>
                {{ user.email }}
              </p>
            </div>
          </div>
          <div class="flex flex-wrap gap-2 sm:justify-end">
            <span :class="statusPillClass(user.active)">
              {{ user.status }}
            </span>
            <span
              v-if="user.activeRestriction"
              :class="restrictionPillClass()"
            >
              {{ user.activeRestriction }}
            </span>
          </div>
        </header>

        <div
          class="grid gap-3 rounded-lg border border-border/60 bg-muted/20 p-3 text-sm sm:grid-cols-4"
        >
          <div class="grid gap-0.5">
            <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('account.header.followers') }}
            </div>
            <div class="font-semibold tabular-nums">
              {{ user.followersCount }}
            </div>
          </div>
          <div class="grid gap-0.5">
            <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('post.feed.title') }}
            </div>
            <div class="font-semibold tabular-nums">{{ user.postsCount }}</div>
          </div>
          <div class="grid gap-0.5">
            <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('account.header.likes') }}
            </div>
            <div class="font-semibold tabular-nums">{{ user.likesCount }}</div>
          </div>
          <div class="grid gap-0.5">
            <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('moderation.users.reportCount') }}
            </div>
            <div
              class="font-semibold tabular-nums"
              :class="user.reportCount > 0 ? 'text-rose-600 dark:text-rose-400' : ''"
            >
              {{ user.reportCount }}
            </div>
          </div>
        </div>

        <div class="flex flex-wrap gap-2 border-t border-border/60 pt-3">
          <Button
            v-if="user.active"
            variant="destructive"
            size="sm"
            class="h-8 rounded-md shadow-xs"
            @click="applyUserAction(user, 'ban')"
          >
            <Ban class="h-3.5 w-3.5" />
            {{ t('moderation.users.ban') }}
          </Button>
          <Button
            v-else
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
            @click="applyUserAction(user, 'unban')"
          >
            <ShieldAlert class="h-3.5 w-3.5" />
            {{ t('moderation.users.unban') }}
          </Button>
          <Button
            v-if="user.activeRestriction !== 'mute'"
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
            @click="applyUserAction(user, 'mute')"
          >
            <VolumeX class="h-3.5 w-3.5" />
            {{ t('moderation.users.mute') }}
          </Button>
          <Button
            v-else
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
            @click="applyUserAction(user, 'unmute')"
          >
            <UsersIcon class="h-3.5 w-3.5" />
            {{ t('moderation.users.unmute') }}
          </Button>
        </div>
      </article>
    </template>

    <div v-if="hasNext" class="flex justify-center pt-1">
      <Button
        variant="outline"
        class="h-9 rounded-md shadow-xs"
        :disabled="loading"
        @click="loadUsers(false)"
      >
        <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
        {{ loading ? t('common.loading') : t('common.loadMore') }}
      </Button>
    </div>
  </div>
</template>
