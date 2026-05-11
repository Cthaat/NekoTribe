<script setup lang="ts">
import { onMounted, ref, watch } from 'vue';
import {
  Ban,
  CheckCircle,
  Search,
  ShieldAlert,
  VolumeX
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
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
  <div class="space-y-4">
    <Card>
      <CardContent class="p-4">
        <div class="flex flex-wrap items-center gap-3">
          <div class="relative min-w-[220px] flex-1">
            <Search class="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              v-model="filters.q"
              class="pl-9"
              :placeholder="t('moderation.users.searchPlaceholder')"
            />
          </div>
          <Select v-model="filters.status">
            <SelectTrigger class="w-[160px]">
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
            <SelectTrigger class="w-[160px]">
              <SelectValue :placeholder="t('moderation.filters.sortPlaceholder')" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="newest">{{ t('moderation.filters.sort.newest') }}</SelectItem>
              <SelectItem value="oldest">{{ t('moderation.filters.sort.oldest') }}</SelectItem>
              <SelectItem value="reports">{{ t('moderation.users.mostReported') }}</SelectItem>
            </SelectContent>
          </Select>
          <Button variant="outline" @click="loadUsers(true)">
            {{ t('moderation.actions.refresh') }}
          </Button>
        </div>
      </CardContent>
    </Card>

    <div v-if="loading && users.length === 0" class="space-y-3">
      <Card v-for="item in 4" :key="item">
        <CardContent class="h-24 animate-pulse bg-muted/50" />
      </Card>
    </div>

    <div v-else-if="users.length === 0" class="rounded-lg border p-10 text-center text-sm text-muted-foreground">
      {{ t('moderation.users.empty') }}
    </div>

    <Card v-for="user in users" v-else :key="user.id">
      <CardHeader class="flex flex-row items-start justify-between space-y-0">
        <div class="flex items-center gap-3">
          <Avatar class="h-11 w-11">
            <AvatarImage :src="user.avatarUrl" />
            <AvatarFallback>{{ initials(user) }}</AvatarFallback>
          </Avatar>
          <div>
            <CardTitle class="flex items-center gap-2 text-base">
              {{ user.name }}
              <CheckCircle v-if="user.verified" class="h-4 w-4 text-primary" />
            </CardTitle>
            <div class="text-sm text-muted-foreground">
              @{{ user.username }} · {{ user.email }}
            </div>
          </div>
        </div>
        <div class="flex flex-wrap justify-end gap-2">
          <Badge :variant="user.active ? 'secondary' : 'destructive'">
            {{ user.status }}
          </Badge>
          <Badge v-if="user.activeRestriction" variant="outline">
            {{ user.activeRestriction }}
          </Badge>
        </div>
      </CardHeader>
      <CardContent class="space-y-4">
        <div class="grid gap-3 text-sm sm:grid-cols-4">
          <div>
            <div class="text-muted-foreground">{{ t('account.header.followers') }}</div>
            <div class="font-medium">{{ user.followersCount }}</div>
          </div>
          <div>
            <div class="text-muted-foreground">{{ t('post.feed.title') }}</div>
            <div class="font-medium">{{ user.postsCount }}</div>
          </div>
          <div>
            <div class="text-muted-foreground">{{ t('account.header.likes') }}</div>
            <div class="font-medium">{{ user.likesCount }}</div>
          </div>
          <div>
            <div class="text-muted-foreground">{{ t('moderation.users.reportCount') }}</div>
            <div class="font-medium">{{ user.reportCount }}</div>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button
            v-if="user.active"
            variant="destructive"
            size="sm"
            class="gap-2"
            @click="applyUserAction(user, 'ban')"
          >
            <Ban class="h-4 w-4" />
            {{ t('moderation.users.ban') }}
          </Button>
          <Button
            v-else
            variant="outline"
            size="sm"
            class="gap-2"
            @click="applyUserAction(user, 'unban')"
          >
            <ShieldAlert class="h-4 w-4" />
            {{ t('moderation.users.unban') }}
          </Button>
          <Button
            v-if="user.activeRestriction !== 'mute'"
            variant="outline"
            size="sm"
            class="gap-2"
            @click="applyUserAction(user, 'mute')"
          >
            <VolumeX class="h-4 w-4" />
            {{ t('moderation.users.mute') }}
          </Button>
          <Button
            v-else
            variant="outline"
            size="sm"
            @click="applyUserAction(user, 'unmute')"
          >
            {{ t('moderation.users.unmute') }}
          </Button>
        </div>
      </CardContent>
    </Card>

    <div v-if="hasNext" class="flex justify-center">
      <Button variant="outline" :disabled="loading" @click="loadUsers(false)">
        {{ loading ? t('common.loading') : t('common.loadMore') }}
      </Button>
    </div>
  </div>
</template>
