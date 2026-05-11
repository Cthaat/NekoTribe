<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
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

const searchQuery = ref('');
const users = ref<PublicUserVM[]>([]);
const isPopoverOpen = ref(false);
const isSearchingUsers = ref(false);
const searchError = ref('');

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
  searchQuery.value = '';
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

watch(
  searchQuery,
  value => {
    clearSearchTimer();
    const query = value.trim();
    const requestId = ++searchRequestId;
    searchError.value = '';

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
          class="h-10 rounded-full pl-9 pr-24"
          @focus="handleFocus"
          @keydown.enter.prevent="submitPostSearch"
          @keydown.esc="closeSearch"
        />
        <Button
          v-if="trimmedQuery"
          type="button"
          variant="secondary"
          size="sm"
          class="absolute right-1 top-1/2 h-8 -translate-y-1/2 rounded-full px-3 text-xs"
          @click="submitPostSearch"
        >
          {{ t('globalSearch.postsAction') }}
        </Button>
      </div>
    </PopoverAnchor>

    <PopoverContent
      align="start"
      class="w-[min(32rem,calc(100vw-2rem))] p-0"
      :side-offset="8"
    >
      <div class="border-b px-3 py-2">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2 text-sm font-medium">
            <UserRound class="h-4 w-4 text-muted-foreground" />
            {{ t('globalSearch.usersTitle') }}
          </div>
          <Badge variant="outline" class="text-[11px]">
            {{ t('globalSearch.enterHint') }}
          </Badge>
        </div>
      </div>

      <div
        v-if="!canSearchUsers"
        class="px-4 py-8 text-center text-sm text-muted-foreground"
      >
        {{ t('globalSearch.minHint') }}
      </div>

      <div v-else-if="isSearchingUsers" class="space-y-3 p-3">
        <div
          v-for="index in 3"
          :key="index"
          class="flex items-center gap-3"
        >
          <Skeleton class="h-10 w-10 rounded-full" />
          <div class="min-w-0 flex-1 space-y-2">
            <Skeleton class="h-4 w-36" />
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
        class="px-4 py-8 text-center text-sm text-muted-foreground"
      >
        {{ t('globalSearch.empty') }}
      </div>

      <ScrollArea v-else class="max-h-80">
        <div class="p-2">
          <Button
            v-for="user in users"
            :key="user.id"
            type="button"
            variant="ghost"
            class="h-auto w-full justify-start gap-3 rounded-md p-2 text-left"
            @click="openUserProfile(user)"
          >
            <Avatar class="h-10 w-10 shrink-0">
              <AvatarImage
                :src="user.avatarUrl"
                :alt="user.name"
              />
              <AvatarFallback>
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
                  class="h-3.5 w-3.5 shrink-0 text-primary"
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
          </Button>
        </div>
      </ScrollArea>
    </PopoverContent>
  </Popover>
</template>
