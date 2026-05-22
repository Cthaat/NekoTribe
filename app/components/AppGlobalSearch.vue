<script setup lang="ts">
import {
  computed,
  nextTick,
  onBeforeUnmount,
  ref,
  watch
} from 'vue';
import { useRoute } from 'vue-router';
import { CheckCircle2, Search, UserRound } from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Popover,
  PopoverAnchor,
  PopoverContent
} from '@/components/ui/popover';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import { v2SearchUsers } from '@/services/users';
import type { PublicUserVM } from '@/types/users';

const MIN_QUERY_LENGTH = 2;

const { t, locale } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();

const searchQuery = ref('');
const users = ref<PublicUserVM[]>([]);
const isPopoverOpen = ref(false);
const isSearchingUsers = ref(false);
const searchError = ref('');
const isSyncingRouteSearch = ref(false);

let searchTimer: ReturnType<typeof setTimeout> | null = null;
let searchRequestId = 0;

const trimmedQuery = computed(() => searchQuery.value.trim());
const canSearchUsers = computed(
  () => trimmedQuery.value.length >= MIN_QUERY_LENGTH
);
const numberFormatter = computed(
  () =>
    new Intl.NumberFormat(
      locale.value === 'zh' ? 'zh-CN' : 'en-US'
    )
);

function clearSearchTimer(): void {
  if (!searchTimer) return;
  clearTimeout(searchTimer);
  searchTimer = null;
}

function avatarFallback(user: PublicUserVM): string {
  const source = user.name || user.username || '?';
  return source.slice(0, 2).toUpperCase();
}

function formatCount(value: number): string {
  return numberFormatter.value.format(value);
}

async function runUserSearch(
  query: string,
  requestId: number
): Promise<void> {
  try {
    const result = await v2SearchUsers({
      q: query,
      page: 1,
      pageSize: 6,
      sort: 'popular'
    });
    if (requestId !== searchRequestId) return;
    users.value = result.items;
  } catch (error) {
    if (requestId !== searchRequestId) return;
    users.value = [];
    searchError.value =
      error instanceof Error
        ? error.message
        : t('globalSearch.failed');
  } finally {
    if (requestId === searchRequestId) {
      isSearchingUsers.value = false;
    }
  }
}

function closeSearch(): void {
  isPopoverOpen.value = false;
}

function submitPostSearch(): void {
  const query = trimmedQuery.value;
  if (!query) return;
  closeSearch();
  void navigateTo(
    localePath(`/tweet/search/${encodeURIComponent(query)}`)
  );
}

function openUserProfile(user: PublicUserVM): void {
  closeSearch();
  searchQuery.value = '';
  void navigateTo(localePath(`/user/${user.id}/profile`));
}

function handleFocus(): void {
  if (trimmedQuery.value) {
    isPopoverOpen.value = true;
  }
}

function handlePopoverOpenChange(open: boolean): void {
  isPopoverOpen.value = open && !!trimmedQuery.value;
}

function routeSearchQuery(): string {
  if (!route.path.includes('/tweet/search/')) return '';
  const value = route.params.search;
  if (Array.isArray(value)) return String(value[0] ?? '');
  return typeof value === 'string' ? value : '';
}

watch(
  searchQuery,
  value => {
    clearSearchTimer();
    const query = value.trim();
    const requestId = ++searchRequestId;
    searchError.value = '';

    if (isSyncingRouteSearch.value) {
      isPopoverOpen.value = false;
      isSearchingUsers.value = false;
      users.value = [];
      return;
    }

    if (!query) {
      isPopoverOpen.value = false;
      isSearchingUsers.value = false;
      users.value = [];
      return;
    }

    isPopoverOpen.value = true;

    if (query.length < MIN_QUERY_LENGTH) {
      isSearchingUsers.value = false;
      users.value = [];
      return;
    }

    isSearchingUsers.value = true;
    searchTimer = setTimeout(() => {
      void runUserSearch(query, requestId);
    }, 250);
  }
);

watch(
  [() => route.path, () => route.params.search],
  () => {
    const query = routeSearchQuery();
    if (!query || query === searchQuery.value) return;
    isSyncingRouteSearch.value = true;
    searchQuery.value = query;
    void nextTick(() => {
      isSyncingRouteSearch.value = false;
    });
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  clearSearchTimer();
});
</script>

<template>
  <Popover
    :open="isPopoverOpen"
    @update:open="handlePopoverOpenChange"
  >
    <PopoverAnchor as-child>
      <div class="relative w-full min-w-0">
        <Search
          class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          v-model="searchQuery"
          type="search"
          :placeholder="t('globalSearch.placeholder')"
          autocomplete="off"
          class="h-9 rounded-md pl-9 pr-24 shadow-xs focus-visible:ring-2 focus-visible:ring-ring/40"
          @focus="handleFocus"
          @keydown.enter.prevent="submitPostSearch"
          @keydown.esc="closeSearch"
        />
        <Button
          v-if="trimmedQuery"
          type="button"
          variant="secondary"
          size="sm"
          class="absolute right-1 top-1/2 h-7 -translate-y-1/2 rounded-md px-2.5 text-xs"
          @click="submitPostSearch"
        >
          {{ t('globalSearch.postsAction') }}
        </Button>
      </div>
    </PopoverAnchor>

    <PopoverContent
      align="start"
      class="w-[min(32rem,calc(100vw-2rem))] overflow-hidden p-0 shadow-lg"
      :side-offset="6"
    >
      <div class="flex items-center justify-between gap-3 border-b px-3 py-2.5">
        <div class="flex items-center gap-2 text-xs font-medium text-muted-foreground">
          <UserRound class="h-3.5 w-3.5" />
          <span>{{ t('globalSearch.usersTitle') }}</span>
        </div>
        <kbd
          class="pointer-events-none inline-flex h-5 select-none items-center gap-1 rounded border bg-muted px-1.5 font-mono text-[10px] font-medium text-muted-foreground"
        >
          {{ t('globalSearch.enterHint') }}
        </kbd>
      </div>

      <div
        v-if="!canSearchUsers"
        class="flex flex-col items-center justify-center gap-1.5 px-4 py-10 text-center"
      >
        <div class="rounded-full bg-muted/60 p-2">
          <Search class="h-4 w-4 text-muted-foreground" />
        </div>
        <p class="text-sm text-muted-foreground">
          {{ t('globalSearch.minHint') }}
        </p>
      </div>

      <div v-else-if="isSearchingUsers" class="space-y-1 p-2">
        <div
          v-for="index in 3"
          :key="index"
          class="flex items-center gap-3 rounded-md px-2 py-2"
        >
          <Skeleton class="h-9 w-9 rounded-full" />
          <div class="min-w-0 flex-1 space-y-1.5">
            <Skeleton class="h-3.5 w-36" />
            <Skeleton class="h-3 w-24" />
          </div>
        </div>
      </div>

      <div
        v-else-if="searchError"
        class="px-4 py-8 text-center text-sm text-destructive"
      >
        {{ searchError }}
      </div>

      <div
        v-else-if="users.length === 0"
        class="flex flex-col items-center justify-center gap-1.5 px-4 py-10 text-center"
      >
        <div class="rounded-full bg-muted/60 p-2">
          <UserRound class="h-4 w-4 text-muted-foreground" />
        </div>
        <p class="text-sm text-muted-foreground">
          {{ t('globalSearch.empty') }}
        </p>
      </div>

      <ScrollArea v-else class="max-h-80">
        <div class="p-1.5">
          <button
            v-for="user in users"
            :key="user.id"
            type="button"
            class="flex w-full items-center gap-3 rounded-md p-2 text-left transition-colors hover:bg-accent hover:text-accent-foreground"
            @click="openUserProfile(user)"
          >
            <Avatar class="h-9 w-9 shrink-0 ring-1 ring-border">
              <AvatarImage
                :src="user.avatarUrl"
                :alt="user.name"
              />
              <AvatarFallback class="text-xs">
                {{ avatarFallback(user) }}
              </AvatarFallback>
            </Avatar>
            <div class="min-w-0 flex-1">
              <div class="flex min-w-0 items-center gap-1.5">
                <span class="truncate text-sm font-medium">
                  {{ user.name }}
                </span>
                <CheckCircle2
                  v-if="user.verified"
                  class="h-3.5 w-3.5 shrink-0 text-sky-500"
                />
              </div>
              <div class="truncate text-xs text-muted-foreground">
                @{{ user.username }} ·
                {{
                  t('globalSearch.followers', {
                    count: formatCount(user.followersCount)
                  })
                }}
              </div>
            </div>
          </button>
        </div>
      </ScrollArea>
    </PopoverContent>
  </Popover>
</template>
