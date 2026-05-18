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
import { Separator } from '@/components/ui/separator';
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import { TooltipProvider } from '@/components/ui/tooltip';
import MailDisplay from '@/components/MailDisplay.vue';
import MailList from '@/components/MailList.vue';
import Nav, {
  type LinkProp
} from '@/components/MailNav.vue';
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
  // 改为可选，以便页面不再强制传入
  accounts?: {
    label: string;
    email: string;
    icon: string;
  }[];
  mails: MailItem[];
  defaultLayout?: number[];
  defaultCollapsed?: boolean;
  navCollapsedSize: number;
  // 新增：下发给列表的加载更多函数
  loadMore?: () => void;
  // 是否是垃圾桶视图
  isTrashView?: boolean;
  loading?: boolean;
}

const emit = defineEmits<{
  (e: 'read-mail', mailId: string): void;
  (e: 'delete-mail', mailId: string): void;
  (e: 'restore-mail', mailId: string): void;
  (
    e: 'set-read-status',
    payload: { mailId: string; read: boolean }
  ): void;
  (e: 'mark-all-read'): void;
  (e: 'refresh'): void;
  (e: 'filter-change', filters: MailFilterPayload): void;
}>();

const props = withDefaults(defineProps<MailProps>(), {
  defaultCollapsed: false,
  defaultLayout: () => [265, 440, 655]
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
    variant:
      currentView.value === option.value ? 'default' : 'ghost'
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

// 暴露当前视图给父组件
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
      <div class="space-y-3 border-b p-3">
        <div class="grid grid-cols-2 gap-2">
          <Button
            v-for="link in links"
            :key="link.value"
            :variant="link.variant"
            class="justify-start"
            @click="handleNavClick(link.value)"
          >
            <Icon :icon="link.icon" class="size-4" />
            {{ link.title }}
          </Button>
        </div>
        <div class="grid grid-cols-2 gap-2">
          <Button
            variant="outline"
            class="justify-start"
            :disabled="props.loading"
            @click="emit('refresh')"
          >
            <RefreshCw class="size-4" />
            {{ t('mail.actions.refresh') }}
          </Button>
          <Button
            variant="outline"
            class="justify-start"
            :disabled="props.loading || isCurrentTrashView"
            @click="emit('mark-all-read')"
          >
            <CheckCheck class="size-4" />
            {{ t('mail.actions.markAllRead') }}
          </Button>
        </div>
        <form>
          <div class="relative">
            <Search
              class="absolute left-2 top-2.5 size-4 text-muted-foreground"
            />
            <Input
              v-model="searchValue"
              :placeholder="t('mail.searchPlaceholder')"
              class="pl-8"
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
          <TabsTrigger
            value="all"
            class="text-zinc-600 dark:text-zinc-200"
          >
            {{ t('mail.tabs.all') }}
          </TabsTrigger>
          <TabsTrigger
            value="unread"
            class="text-zinc-600 dark:text-zinc-200"
          >
            {{ t('mail.tabs.unread') }}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="all" class="m-0">
          <MailList
            v-model:selectedMail="selectedMail"
            :items="filteredMailList"
            :load-more="props.loadMore"
            @read-mail="handleReadMail"
          />
        </TabsContent>
        <TabsContent value="unread" class="m-0">
          <MailList
            v-model:selectedMail="selectedMail"
            :items="unreadMailList"
            :load-more="props.loadMore"
            @read-mail="handleReadMail"
          />
        </TabsContent>
      </Tabs>

      <MailDisplay
        class="min-h-72 border-t"
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
          @update:model-value="handleTabChange"
        >
          <div class="flex flex-wrap items-center gap-2 px-4 py-2">
            <h1 class="text-xl font-bold">
              {{ currentViewOption?.title }}
            </h1>
            <div class="ml-auto flex items-center gap-2">
              <TabsList>
                <TabsTrigger
                  value="all"
                  class="text-zinc-600 dark:text-zinc-200"
                >
                  {{ t('mail.tabs.all') }}
                </TabsTrigger>
                <TabsTrigger
                  value="unread"
                  class="text-zinc-600 dark:text-zinc-200"
                >
                  {{ t('mail.tabs.unread') }}
                </TabsTrigger>
              </TabsList>
              <Button
                variant="ghost"
                size="icon"
                :disabled="props.loading"
                @click="emit('refresh')"
              >
                <RefreshCw class="size-4" />
                <span class="sr-only">{{
                  t('mail.actions.refresh')
                }}</span>
              </Button>
              <Button
                variant="ghost"
                size="icon"
                :disabled="props.loading || isCurrentTrashView"
                @click="emit('mark-all-read')"
              >
                <CheckCheck class="size-4" />
                <span class="sr-only">{{
                  t('mail.actions.markAllRead')
                }}</span>
              </Button>
            </div>
          </div>
          <Separator />
          <div
            class="bg-background/95 p-4 backdrop-blur supports-[backdrop-filter]:bg-background/60"
          >
            <form>
              <div class="relative">
                <Search
                  class="absolute left-2 top-2.5 size-4 text-muted-foreground"
                />
                <Input
                  v-model="searchValue"
                  :placeholder="t('mail.searchPlaceholder')"
                  class="pl-8"
                />
              </div>
            </form>
          </div>
          <TabsContent value="all" class="m-0">
            <MailList
              v-model:selectedMail="selectedMail"
              :items="filteredMailList"
              :load-more="props.loadMore"
              @read-mail="handleReadMail"
            />
          </TabsContent>
          <TabsContent value="unread" class="m-0">
            <MailList
              v-model:selectedMail="selectedMail"
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
