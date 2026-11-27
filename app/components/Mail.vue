<script lang="ts" setup>
import { refDebounced } from '@vueuse/core';
import { Icon } from '@iconify/vue';
import {
  Bell,
  CheckCheck,
  Inbox,
  ListChecks,
  MoreHorizontal,
  RefreshCw,
  Search,
  Trash2,
  X
} from 'lucide-vue-next';
import { computed, ref, watch } from 'vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Dialog,
  DialogContent
} from '@/components/ui/dialog';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
import MailDisplay from '@/components/MailDisplay.vue';
import MailList from '@/components/MailList.vue';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import type { MailItem } from './mail/types';

type MailView =
  | 'inbox'
  | 'unread'
  | 'like'
  | 'comment'
  | 'retweet'
  | 'follow'
  | 'mention'
  | 'login_alert'
  | 'system'
  | 'trash';

type PrimaryTab = 'all' | 'unread' | 'mentions' | 'system';

interface MailFilterPayload {
  type: string;
  unreadOnly: boolean;
  showDeleted: boolean;
}

interface MailProps {
  accounts?: {
    label: string;
    email: string;
    icon: string;
  }[];
  mails: MailItem[];
  defaultLayout?: number[];
  defaultCollapsed?: boolean;
  navCollapsedSize?: number;
  loadMore?: () => void;
  isTrashView?: boolean;
  loading?: boolean;
  markingListed?: boolean;
}

defineOptions({
  name: 'NotificationMail'
});

const emit = defineEmits<{
  (
    e: 'read-mail' | 'delete-mail' | 'restore-mail',
    mailId: string
  ): void;
  (
    e: 'set-read-status',
    payload: { mailId: string; read: boolean }
  ): void;
  (e: 'mark-all-read' | 'refresh'): void;
  (e: 'mark-listed-read', mailIds: string[]): void;
  (e: 'filter-change', filters: MailFilterPayload): void;
}>();

const props = withDefaults(defineProps<MailProps>(), {
  accounts: () => [],
  defaultCollapsed: false,
  defaultLayout: () => [265, 440, 655],
  navCollapsedSize: 4,
  loadMore: undefined,
  isTrashView: false,
  loading: false
});

const { t } = useAppLocale();
const selectedMail = ref<string | undefined>(
  props.mails[0]?.id ? String(props.mails[0]?.id) : undefined
);
const isDetailOpen = ref(false);
const searchOpen = ref(false);
const searchValue = ref('');
const debouncedSearch = refDebounced(searchValue, 250);
const currentView = ref<MailView>('inbox');
const activeTab = ref<'all' | 'unread'>('all');
const clientCategory = ref<'all' | 'mentions' | 'system'>('all');

const viewOptions = computed<
  Array<{
    value: MailView;
    title: string;
    icon: string;
    type: string;
    showDeleted?: boolean;
    forceUnread?: boolean;
  }>
>(() => [
  {
    value: 'inbox',
    title: t('mail.folders.inbox'),
    icon: 'lucide:inbox',
    type: 'all'
  },
  {
    value: 'unread',
    title: t('mail.folders.unread'),
    icon: 'lucide:mail-warning',
    type: 'all',
    forceUnread: true
  },
  {
    value: 'like',
    title: t('mail.folders.likes'),
    icon: 'lucide:heart',
    type: 'like'
  },
  {
    value: 'comment',
    title: t('mail.folders.comments'),
    icon: 'lucide:message-circle',
    type: 'comment'
  },
  {
    value: 'retweet',
    title: t('mail.folders.retweets'),
    icon: 'lucide:repeat-2',
    type: 'retweet'
  },
  {
    value: 'follow',
    title: t('mail.folders.follows'),
    icon: 'lucide:user-plus',
    type: 'follow'
  },
  {
    value: 'mention',
    title: t('mail.folders.mentions'),
    icon: 'lucide:at-sign',
    type: 'mention'
  },
  {
    value: 'login_alert',
    title: t('mail.folders.security'),
    icon: 'lucide:shield-alert',
    type: 'login_alert'
  },
  {
    value: 'system',
    title: t('mail.folders.system'),
    icon: 'lucide:bell',
    type: 'system'
  },
  {
    value: 'trash',
    title: t('mail.folders.trash'),
    icon: 'lucide:trash-2',
    type: 'all',
    showDeleted: true
  }
]);

const currentViewOption = computed(
  () =>
    viewOptions.value.find(option => option.value === currentView.value) ??
    viewOptions.value[0]
);

const isCurrentTrashView = computed(
  () => currentView.value === 'trash' || props.isTrashView
);

const filteredMailList = computed(() => {
  let output: MailItem[] = props.mails;
  if (clientCategory.value === 'mentions') {
    output = output.filter(item =>
      ['mention', 'comment', 'reply', 'group_comment'].includes(item.type)
    );
  } else if (clientCategory.value === 'system') {
    output = output.filter(item =>
      ['system', 'login_alert', 'security'].includes(item.type)
    );
  }

  const normalizedSearch = debouncedSearch.value?.trim().toLowerCase();
  if (!normalizedSearch) return output;

  return output.filter(item => {
    const searchableText = [
      item.name,
      item.email,
      item.subject,
      item.text,
      item.typeLabel,
      item.primaryPreview?.text,
      item.secondaryPreview?.text
    ]
      .filter((value): value is string => Boolean(value))
      .join(' ')
      .toLowerCase();
    return searchableText.includes(normalizedSearch);
  });
});

const unreadMailList = computed(() =>
  filteredMailList.value.filter(item => !item.read)
);

const displayList = computed(() =>
  activeTab.value === 'unread' ? unreadMailList.value : filteredMailList.value
);

const canMarkListed = computed(
  () =>
    !props.loading &&
    !props.markingListed &&
    !isCurrentTrashView.value &&
    unreadMailList.value.length > 0
);

function markListedRead() {
  if (canMarkListed.value) {
    emit(
      'mark-listed-read',
      unreadMailList.value.map(item => item.id)
    );
  }
}

const selectedMailData = computed(() =>
  props.mails.find(item => item.id === selectedMail.value)
);

function emitFilterChange(
  view = currentView.value,
  tab = activeTab.value
) {
  const option =
    viewOptions.value.find(item => item.value === view) ??
    viewOptions.value[0];
  if (!option) return;

  emit('filter-change', {
    type: option.type,
    unreadOnly: Boolean(option.forceUnread) || tab === 'unread',
    showDeleted: Boolean(option.showDeleted)
  });
}

function handleNavClick(value: string) {
  const nextView = viewOptions.value.find(
    option => option.value === value
  )?.value;
  if (!nextView) return;

  currentView.value = nextView;
  clientCategory.value = 'all';
  activeTab.value = nextView === 'unread' ? 'unread' : 'all';
  selectedMail.value = undefined;
  emitFilterChange(nextView, activeTab.value);
}

const activePrimaryTab = computed<PrimaryTab>(() => {
  if (activeTab.value === 'unread' || currentView.value === 'unread') {
    return 'unread';
  }
  if (clientCategory.value === 'mentions') return 'mentions';
  if (clientCategory.value === 'system') return 'system';
  return 'all';
});

function selectPrimaryTab(tab: PrimaryTab) {
  selectedMail.value = undefined;
  if (tab === 'unread') {
    currentView.value = 'inbox';
    clientCategory.value = 'all';
    activeTab.value = 'unread';
    emitFilterChange('inbox', 'unread');
    return;
  }

  const needsServerReset =
    currentView.value !== 'inbox' || activeTab.value !== 'all';
  currentView.value = 'inbox';
  activeTab.value = 'all';
  clientCategory.value =
    tab === 'mentions' ? 'mentions' : tab === 'system' ? 'system' : 'all';
  if (needsServerReset) {
    emitFilterChange('inbox', 'all');
  }
}

defineExpose({
  currentView
});

function handleReadMail(mailId: string) {
  emit('read-mail', mailId);
}

function handleOpenDetails(mailId: string) {
  selectedMail.value = mailId;
  isDetailOpen.value = true;
}

watch(
  filteredMailList,
  items => {
    if (
      selectedMail.value &&
      items.some(item => item.id === selectedMail.value)
    ) {
      return;
    }
    selectedMail.value = items[0]?.id;
  },
  { immediate: true }
);
</script>

<template>
  <TooltipProvider :delay-duration="0">
    <div class="flex min-h-dvh flex-col bg-background">
      <!-- Sticky Frosted Header + Capsule Tabs -->
      <header
        class="sticky top-0 z-20 bg-[var(--glass-bg)] backdrop-blur-md"
      >
        <div class="flex items-center justify-between gap-2 px-4 py-2.5">
          <div class="flex min-w-0 items-center gap-2">
            <h1 class="truncate text-lg font-bold tracking-tight text-foreground">
              {{
                isCurrentTrashView
                  ? t('mail.folders.trash')
                  : currentView !== 'inbox' && currentView !== 'unread'
                    ? currentViewOption?.title
                    : t('nav.main.notifications')
              }}
            </h1>
            <span
              v-if="unreadMailList.length > 0 && !isCurrentTrashView"
              class="inline-flex h-5 items-center rounded-full bg-primary/12 px-2 text-xs font-bold tabular-nums text-primary"
            >
              {{ unreadMailList.length }}
            </span>
          </div>

          <div class="flex shrink-0 items-center gap-1">
            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  class="size-9 rounded-full text-muted-foreground hover:bg-[var(--hover)] hover:text-foreground"
                  :aria-label="t(searchOpen ? 'common.close' : 'common.search')"
                  :aria-expanded="searchOpen"
                  @click="searchOpen = !searchOpen"
                >
                  <X v-if="searchOpen" class="size-4" />
                  <Search v-else class="size-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>{{ t('mail.searchPlaceholder') }}</TooltipContent>
            </Tooltip>

            <Tooltip>
              <TooltipTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  class="size-9 rounded-full transition-colors"
                  :class="
                    isCurrentTrashView
                      ? 'bg-primary/12 text-primary'
                      : 'text-muted-foreground hover:bg-[var(--hover)] hover:text-foreground'
                  "
                  :aria-label="t(isCurrentTrashView ? 'mail.folders.inbox' : 'mail.folders.trash')"
                  @click="handleNavClick(isCurrentTrashView ? 'inbox' : 'trash')"
                >
                  <Inbox v-if="isCurrentTrashView" class="size-4" />
                  <Trash2 v-else class="size-4" />
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                {{ isCurrentTrashView ? t('mail.folders.inbox') : t('mail.folders.trash') }}
              </TooltipContent>
            </Tooltip>

            <Button
              variant="ghost"
              size="sm"
              class="h-9 gap-1.5 rounded-full px-3 text-xs font-semibold text-primary hover:bg-primary/10"
              :disabled="props.loading || isCurrentTrashView"
              @click="emit('mark-all-read')"
            >
              <CheckCheck class="size-4" />
              <span class="hidden sm:inline">{{ t('mail.actions.markAllRead') }}</span>
            </Button>

            <DropdownMenu>
              <DropdownMenuTrigger as-child>
                <Button
                  variant="ghost"
                  size="icon"
                  class="size-9 rounded-full text-muted-foreground hover:bg-[var(--hover)] hover:text-foreground"
                  :aria-label="t('mail.display.more')"
                >
                  <MoreHorizontal class="size-4" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" class="w-52 rounded-2xl p-1.5">
                <DropdownMenuItem
                  :disabled="props.loading"
                  @select="emit('refresh')"
                >
                  <RefreshCw class="mr-2 size-4" :class="{ 'animate-spin': props.loading }" />
                  <span>{{ t('mail.actions.refresh') }}</span>
                </DropdownMenuItem>
                <DropdownMenuItem
                  :disabled="!canMarkListed"
                  @select="markListedRead"
                >
                  <ListChecks class="mr-2 size-4" />
                  <span>{{ t('notifications.mail.markListedRead') }}</span>
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem
                  v-for="option in viewOptions"
                  :key="option.value"
                  @select="handleNavClick(option.value)"
                >
                  <Icon :icon="option.icon" class="mr-2 size-4" />
                  <span :class="currentView === option.value ? 'font-bold text-primary' : ''">
                    {{ option.title }}
                  </span>
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>

        <div v-if="searchOpen || searchValue" class="px-4 pb-2.5">
          <div class="relative">
            <Search
              class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
            />
            <Input
              v-model="searchValue"
              :placeholder="t('mail.searchPlaceholder')"
              class="h-9 rounded-full border-[var(--divider)] bg-secondary/50 pl-9 pr-4 text-sm shadow-none"
            />
          </div>
        </div>

        <!-- 4 Capsule Filter Tabs -->
        <div
          v-if="!isCurrentTrashView"
          class="px-3 pb-2.5 sm:px-4"
        >
          <div
            role="tablist"
            class="flex items-center gap-1 rounded-full bg-secondary p-1"
          >
            <button
              v-for="tab in ([
                { key: 'all', label: t('mail.tabs.all') },
                { key: 'unread', label: t('mail.tabs.unread') },
                { key: 'mentions', label: t('mail.tabs.mentions') },
                { key: 'system', label: t('mail.tabs.system') }
              ] as const)"
              :key="tab.key"
              type="button"
              role="tab"
              :aria-selected="activePrimaryTab === tab.key"
              class="flex-1 rounded-full py-1.5 text-center text-[13px] transition-all duration-200"
              :class="
                activePrimaryTab === tab.key && (currentView === 'inbox' || currentView === 'unread')
                  ? 'bg-card font-semibold text-foreground shadow-xs dark:shadow-none'
                  : 'font-medium text-muted-foreground hover:text-foreground'
              "
              @click="selectPrimaryTab(tab.key)"
            >
              <span>{{ tab.label }}</span>
            </button>
          </div>
        </div>
      </header>

      <!-- Stream Content -->
      <div v-if="props.loading && displayList.length === 0" class="space-y-2.5 px-3 py-3 sm:px-4">
        <TweetCardSkeleton v-for="i in 4" :key="i" />
      </div>

      <div
        v-else-if="displayList.length === 0"
        class="px-3 py-8 sm:px-4"
      >
        <AppEmptyState :title="t('mail.display.noSelection')" compact />
      </div>

      <MailList
        v-else
        v-model:selected-mail="selectedMail"
        :items="displayList"
        :load-more="props.loadMore"
        :is-trash-view="isCurrentTrashView"
        @read-mail="handleReadMail"
        @open-details="handleOpenDetails"
        @set-read-status="emit('set-read-status', $event)"
        @delete-mail="emit('delete-mail', $event)"
        @restore-mail="emit('restore-mail', $event)"
      />

      <!-- Detail Modal -->
      <Dialog v-model:open="isDetailOpen">
        <DialogContent class="max-h-[85dvh] max-w-xl overflow-hidden rounded-2xl border-[var(--divider)] p-0">
          <MailDisplay
            :mail="selectedMailData"
            :is-trash-view="isCurrentTrashView"
            @delete-mail="id => { emit('delete-mail', id); isDetailOpen = false; }"
            @restore-mail="id => { emit('restore-mail', id); isDetailOpen = false; }"
            @set-read-status="emit('set-read-status', $event)"
          />
        </DialogContent>
      </Dialog>
    </div>
  </TooltipProvider>
</template>
