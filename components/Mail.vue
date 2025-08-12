<script lang="ts" setup>
import type { Mail } from '@/data/mails';

import { refDebounced } from '@vueuse/core';
import { Search } from 'lucide-vue-next';
import { computed, ref } from 'vue';
import { cn } from '@/lib/utils';
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
import AccountSwitcher from '@/components/AccountSwitcher.vue';
import MailDisplay from '@/components/MailDisplay.vue';
import MailList from '@/components/MailList.vue';
import Nav, {
  type LinkProp
} from '@/components/MailNav.vue';

interface MailProps {
  // 改为可选，以便页面不再强制传入
  accounts?: {
    label: string;
    email: string;
    icon: string;
  }[];
  mails: Mail[];
  defaultLayout?: number[];
  defaultCollapsed?: boolean;
  navCollapsedSize: number;
  // 新增：下发给列表的加载更多函数
  loadMore?: () => void;
}

const emit = defineEmits(['read-mail', 'delete-mail']);

const props = withDefaults(defineProps<MailProps>(), {
  defaultCollapsed: false,
  defaultLayout: () => [265, 440, 655]
});

const isCollapsed = ref(props.defaultCollapsed);
const selectedMail = ref<string | undefined>(
  props.mails[0]?.id
    ? String(props.mails[0]?.id)
    : undefined
);
const searchValue = ref('');
const debouncedSearch = refDebounced(searchValue, 250);

const filteredMailList = computed(() => {
  let output: Mail[] = [];
  const searchValue = debouncedSearch.value?.trim();
  if (!searchValue) {
    output = props.mails;
  } else {
    output = props.mails.filter(item => {
      return (
        item.name.includes(debouncedSearch.value) ||
        item.email.includes(debouncedSearch.value) ||
        item.name.includes(debouncedSearch.value) ||
        item.subject.includes(debouncedSearch.value) ||
        item.text.includes(debouncedSearch.value)
      );
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

// TODO: 后续功能
const links: LinkProp[] = [
  {
    title: 'Inbox',
    label: '128',
    icon: 'lucide:inbox',
    variant: 'default'
  }
  // {
  //   title: 'Drafts',
  //   label: '9',
  //   icon: 'lucide:file',
  //   variant: 'ghost'
  // },
  // {
  //   title: 'Sent',
  //   label: '',
  //   icon: 'lucide:send',
  //   variant: 'ghost'
  // },
  // {
  //   title: 'Trash',
  //   label: '',
  //   icon: 'lucide:trash',
  //   variant: 'ghost'
  // },
  // {
  //   title: 'Archive',
  //   label: '',
  //   icon: 'lucide:archive',
  //   variant: 'ghost'
  // }
];

function onCollapse() {
  isCollapsed.value = true;
}

function onExpand() {
  isCollapsed.value = false;
}

function handleReadMail(mailId: string) {
  emit('read-mail', mailId);
}
</script>

<template>
  <TooltipProvider :delay-duration="0">
    <ResizablePanelGroup
      id="resize-panel-group-1"
      direction="horizontal"
      class="h-dvh items-stretch"
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
        <Nav :is-collapsed="isCollapsed" :links="links" />
      </ResizablePanel>
      <ResizableHandle id="resize-handle-1" with-handle />
      <ResizablePanel
        id="resize-panel-2"
        :default-size="defaultLayout[1]"
        :min-size="30"
      >
        <Tabs default-value="all">
          <div class="flex items-center px-4 py-2">
            <h1 class="text-xl font-bold">Inbox</h1>
            <TabsList class="ml-auto">
              <TabsTrigger
                value="all"
                class="text-zinc-600 dark:text-zinc-200"
              >
                All mail
              </TabsTrigger>
              <TabsTrigger
                value="unread"
                class="text-zinc-600 dark:text-zinc-200"
              >
                Unread
              </TabsTrigger>
            </TabsList>
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
                  placeholder="Search"
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
          @delete-mail="emit('delete-mail', $event)"
        />
      </ResizablePanel>
    </ResizablePanelGroup>
  </TooltipProvider>
</template>
