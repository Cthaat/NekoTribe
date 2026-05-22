<script lang="ts" setup>
import { refDebounced } from '@vueuse/core';
import { Icon } from '@iconify/vue';
import { CheckCheck, RefreshCw, Search } from 'lucide-vue-next';
import { computed, ref, watch } from 'vue';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup
} from '@/components/ui/resizable';
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
import MailDisplay from '@/components/MailDisplay.vue';
import MailList from '@/components/MailList.vue';
import Nav from '@/components/MailNav.vue';
import type { LinkProp } from '@/components/MailNav.vue';
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
  navCollapsedSize: number;
  loadMore?: () => void;
  isTrashView?: boolean;
  loading?: boolean;
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
  (e: 'filter-change', filters: MailFilterPayload): void;
}>();

const props = withDefaults(defineProps<MailProps>(), {
  accounts: () => [],
  defaultCollapsed: false,
  defaultLayout: () => [265, 440, 655],
  loadMore: undefined,
  isTrashView: false,
  loading: false
});

const { t } = useAppLocale();
const isCollapsed = ref(props.defaultCollapsed);
const selectedMail = ref<string | undefined>(
  props.mails[0]?.id
    ? String(props.mails[0]?.id)
    : undefined
);
const searchValue = ref('');
const debouncedSearch = refDebounced(searchValue, 250);
const currentView = ref<MailView>('inbox');
const activeTab = ref<'all' | 'unread'>('all');

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
    viewOptions.value.find(
      option => option.value === currentView.value
    ) ?? viewOptions.value[0]
);

const isCurrentTrashView = computed(
  () => currentView.value === 'trash' || props.isTrashView
);

const filteredMailList = computed(() => {
  let output: MailItem[] = [];
  const normalizedSearch = debouncedSearch.value
    ?.trim()
    .toLowerCase();
  if (!normalizedSearch) {
    output = props.mails;
  } else {
    output = props.mails.filter(item => {
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
  }

  return output;
});

const unreadMailList = computed(() =>
  filteredMailList.value.filter(item => !item.read)
);

const selectedMailData = computed(() =>
  props.mails.find(item => item.id === selectedMail.value)
);

const links = computed<LinkProp[]>(() => [
  ...viewOptions.value.map(option => ({
    value: option.value,
    title: option.title,
    icon: option.icon,
    variant: (
      currentView.value === option.value ? 'default' : 'ghost'
    ) as LinkProp['variant']
  }))
]);

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
    unreadOnly:
      Boolean(option.forceUnread) || tab === 'unread',
    showDeleted: Boolean(option.showDeleted)
  });
}

function resetSelectedMail() {
  selectedMail.value = undefined;
}

function handleNavClick(value: string) {
  const nextView = viewOptions.value.find(
    option => option.value === value
  )?.value;
  if (!nextView) return;

  currentView.value = nextView;
  activeTab.value = nextView === 'unread' ? 'unread' : 'all';
  resetSelectedMail();
  emitFilterChange(nextView, activeTab.value);
}

function handleTabChange(value: string | number) {
  activeTab.value = value === 'unread' ? 'unread' : 'all';
  if (currentView.value === 'unread' && activeTab.value === 'all') {
    currentView.value = 'inbox';
  }
  resetSelectedMail();
  emitFilterChange();
}

defineExpose({
  currentView
});

function onCollapse() {
  isCollapsed.value = true;
}

function onExpand() {
  isCollapsed.value = false;
}

function handleReadMail(mailId: string) {
  emit('read-mail', mailId);
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
    <div class="flex min-h-[calc(100dvh-4rem)] flex-col md:hidden">
      <div
        class="space-y-3 border-b border-border/60 bg-background/60 p-3 backdrop-blur"
      >
        <div class="grid grid-cols-2 gap-1.5">
          <button
            v-for="link in links"
            :key="link.value"
            type="button"
            :class="
              cn(
                'group/nav relative flex h-9 items-center gap-2 rounded-md px-2.5 text-left text-sm transition-colors',
                link.variant === 'default'
                  ? 'bg-accent text-accent-foreground'
                  : 'text-muted-foreground hover:bg-accent/50 hover:text-foreground'
              )
            "
            @click="handleNavClick(link.value)"
          >
            <span
              v-if="link.variant === 'default'"
              class="absolute inset-y-1.5 left-0 w-0.5 rounded-full bg-primary"
              aria-hidden="true"
            />
            <Icon :icon="link.icon" class="size-4 shrink-0" />
            <span
              class="min-w-0 flex-1 truncate"
              :class="link.variant === 'default' ? 'font-medium text-foreground' : ''"
            >
              {{ link.title }}
            </span>
          </button>
        </div>
        <div class="grid grid-cols-2 gap-1.5">
          <Button
            variant="outline"
            size="sm"
            class="h-8 justify-start shadow-xs"
            :disabled="props.loading"
            @click="emit('refresh')"
          >
            <RefreshCw class="size-3.5" />
            {{ t('mail.actions.refresh') }}
          </Button>
          <Button
            variant="outline"
            size="sm"
            class="h-8 justify-start shadow-xs"
            :disabled="props.loading || isCurrentTrashView"
            @click="emit('mark-all-read')"
          >
            <CheckCheck class="size-3.5" />
            {{ t('mail.actions.markAllRead') }}
          </Button>
        </div>
        <form>
          <div class="relative">
            <Search
              class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
            />
            <Input
              v-model="searchValue"
              :placeholder="t('mail.searchPlaceholder')"
              class="h-9 pl-8 shadow-xs"
            />
          </div>
        </form>
      </div>

      <Tabs
        :model-value="activeTab"
        class="min-h-0 flex-1"
        @update:model-value="handleTabChange"
      >
        <TabsList class="mx-3 mt-3 grid grid-cols-2">
          <TabsTrigger value="all">
            {{ t('mail.tabs.all') }}
          </TabsTrigger>
          <TabsTrigger value="unread">
            {{ t('mail.tabs.unread') }}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="all" class="m-0">
          <MailList
            v-model:selected-mail="selectedMail"
            :items="filteredMailList"
            :load-more="props.loadMore"
            @read-mail="handleReadMail"
          />
        </TabsContent>
        <TabsContent value="unread" class="m-0">
          <MailList
            v-model:selected-mail="selectedMail"
            :items="unreadMailList"
            :load-more="props.loadMore"
            @read-mail="handleReadMail"
          />
        </TabsContent>
      </Tabs>

      <MailDisplay
        class="min-h-72 border-t border-border/60"
        :mail="selectedMailData"
        :is-trash-view="isCurrentTrashView"
        @delete-mail="emit('delete-mail', $event)"
        @restore-mail="emit('restore-mail', $event)"
        @set-read-status="emit('set-read-status', $event)"
      />
    </div>

    <ResizablePanelGroup
      id="resize-panel-group-1"
      direction="horizontal"
      class="hidden h-dvh items-stretch md:flex"
    >
      <ResizablePanel
        id="resize-panel-1"
        :default-size="defaultLayout[0]"
        :collapsed-size="navCollapsedSize"
        collapsible
        :min-size="15"
        :max-size="20"
        :class="
          cn(
            isCollapsed &&
              'min-w-[50px] transition-all duration-300 ease-in-out'
          )
        "
        @expand="onExpand"
        @collapse="onCollapse"
      >
        <Nav
          :is-collapsed="isCollapsed"
          :links="links"
          @nav-click="handleNavClick"
        />
      </ResizablePanel>
      <ResizableHandle id="resize-handle-1" with-handle />
      <ResizablePanel
        id="resize-panel-2"
        :default-size="defaultLayout[1]"
        :min-size="30"
      >
        <Tabs
          :model-value="activeTab"
          class="flex h-full flex-col"
          @update:model-value="handleTabChange"
        >
          <div
            class="flex h-12 shrink-0 flex-wrap items-center gap-2 border-b border-border/60 bg-background/60 px-4 backdrop-blur"
          >
            <h1 class="text-base font-semibold tracking-tight">
              {{ currentViewOption?.title }}
            </h1>
            <div class="ml-auto flex items-center gap-1">
              <TabsList class="h-8">
                <TabsTrigger value="all" class="h-6 text-xs">
                  {{ t('mail.tabs.all') }}
                </TabsTrigger>
                <TabsTrigger value="unread" class="h-6 text-xs">
                  {{ t('mail.tabs.unread') }}
                </TabsTrigger>
              </TabsList>
              <Tooltip>
                <TooltipTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
                    :disabled="props.loading"
                    @click="emit('refresh')"
                  >
                    <RefreshCw class="size-4" :class="{ 'animate-spin': props.loading }" />
                    <span class="sr-only">{{
                      t('mail.actions.refresh')
                    }}</span>
                  </Button>
                </TooltipTrigger>
                <TooltipContent>{{ t('mail.actions.refresh') }}</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
                    :disabled="props.loading || isCurrentTrashView"
                    @click="emit('mark-all-read')"
                  >
                    <CheckCheck class="size-4" />
                    <span class="sr-only">{{
                      t('mail.actions.markAllRead')
                    }}</span>
                  </Button>
                </TooltipTrigger>
                <TooltipContent>{{ t('mail.actions.markAllRead') }}</TooltipContent>
              </Tooltip>
            </div>
          </div>
          <div
            class="shrink-0 border-b border-border/60 bg-muted/20 p-3"
          >
            <form>
              <div class="relative">
                <Search
                  class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
                />
                <Input
                  v-model="searchValue"
                  :placeholder="t('mail.searchPlaceholder')"
                  class="h-9 pl-8 shadow-xs"
                />
              </div>
            </form>
          </div>
          <TabsContent value="all" class="m-0 min-h-0 flex-1">
            <MailList
              v-model:selected-mail="selectedMail"
              :items="filteredMailList"
              :load-more="props.loadMore"
              @read-mail="handleReadMail"
            />
          </TabsContent>
          <TabsContent value="unread" class="m-0 min-h-0 flex-1">
            <MailList
              v-model:selected-mail="selectedMail"
              :items="unreadMailList"
              :load-more="props.loadMore"
              @read-mail="handleReadMail"
            />
          </TabsContent>
        </Tabs>
      </ResizablePanel>
      <ResizableHandle id="resiz-handle-2" with-handle />
      <ResizablePanel
        id="resize-panel-3"
        :default-size="defaultLayout[2]"
      >
        <MailDisplay
          :mail="selectedMailData"
          :is-trash-view="isCurrentTrashView"
          @delete-mail="emit('delete-mail', $event)"
          @restore-mail="emit('restore-mail', $event)"
          @set-read-status="emit('set-read-status', $event)"
        />
      </ResizablePanel>
    </ResizablePanelGroup>
  </TooltipProvider>
</template>
