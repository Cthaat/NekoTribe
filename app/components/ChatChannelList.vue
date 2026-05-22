<script setup lang="ts">
import { ref, computed } from 'vue';
import {
  Hash,
  Volume2,
  Video,
  Megaphone,
  Lock,
  Plus,
  Settings,
  ChevronDown,
  ChevronRight,
  Bell,
  BellOff,
  Edit3,
  Trash2,
  Users,
  Check
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger
} from '@/components/ui/collapsible';
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

const { t } = useAppLocale();

// 频道类型定义
export interface Channel {
  id: number;
  name: string;
  type: 'text' | 'voice' | 'video' | 'announcement';
  isPrivate?: boolean;
  unreadCount?: number;
  isMuted?: boolean;
  lastMessage?: string;
  lastMessageTime?: string;
}

export interface ChannelCategory {
  id: number;
  name: string;
  channels: Channel[];
  isCollapsed?: boolean;
}

export interface ChannelListGroup {
  id: number;
  name: string;
  unreadCount?: number;
}

const props = defineProps<{
  categories: ChannelCategory[];
  activeChannelId?: number;
  groupName?: string;
  groupAvatar?: string;
  canManage?: boolean;
  currentUserName?: string;
  groups?: ChannelListGroup[];
  activeGroupId?: number;
}>();

const emit = defineEmits<{
  (e: 'select', channel: Channel): void;
  (e: 'select-group', groupId: number): void;
  (e: 'create-channel', categoryId: number): void;
  (e: 'edit-channel', channel: Channel): void;
  (e: 'delete-channel', channelId: number): void;
  (e: 'toggle-mute', channelId: number): void;
  (e: 'toggle-category', categoryId: number): void;
  (e: 'invite-members'): void;
  (e: 'notification-settings'): void;
  (e: 'settings'): void;
}>();

// 折叠状态
const collapsedCategories = ref<Set<number>>(new Set());

// 获取频道图标
const getChannelIcon = (type: Channel['type']) => {
  switch (type) {
    case 'text':
      return Hash;
    case 'voice':
      return Volume2;
    case 'video':
      return Video;
    case 'announcement':
      return Megaphone;
    default:
      return Hash;
  }
};

// 切换分类折叠状态
const toggleCategory = (categoryId: number) => {
  if (collapsedCategories.value.has(categoryId)) {
    collapsedCategories.value.delete(categoryId);
  } else {
    collapsedCategories.value.add(categoryId);
  }
  emit('toggle-category', categoryId);
};

// 是否折叠
const isCollapsed = (categoryId: number) => {
  return collapsedCategories.value.has(categoryId);
};

// 选择频道
const selectChannel = (channel: Channel) => {
  if (
    channel.type === 'text' ||
    channel.type === 'announcement'
  ) {
    emit('select', channel);
  }
};

const currentUserInitials = computed(() => {
  const name = props.currentUserName || t('chat.currentUser.name');
  return name.slice(0, 2);
});
</script>

<template>
  <div class="flex h-full min-h-0 flex-col overflow-hidden bg-muted/20">
    <div class="shrink-0 border-b border-border/60 bg-background/60 p-2 backdrop-blur">
      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            class="h-9 w-full justify-between rounded-md px-2 text-sm font-semibold"
          >
            <span class="truncate">
              {{ groupName || t('chat.groupFallbackName') }}
            </span>
            <ChevronDown class="h-4 w-4 shrink-0 text-muted-foreground" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent class="w-60" align="start">
          <template v-if="groups?.length">
            <DropdownMenuItem
              v-for="group in groups"
              :key="group.id"
              @click="emit('select-group', group.id)"
            >
              <Check
                class="h-4 w-4"
                :class="{
                  'opacity-100': group.id === activeGroupId,
                  'opacity-0': group.id !== activeGroupId
                }"
              />
              <span class="min-w-0 flex-1 truncate">
                {{ group.name }}
              </span>
              <span
                v-if="group.unreadCount"
                class="ml-2 inline-flex h-4 min-w-[16px] items-center justify-center rounded-full bg-primary px-1 text-[10px] font-medium tabular-nums text-primary-foreground"
              >
                {{ group.unreadCount > 99 ? '99+' : group.unreadCount }}
              </span>
            </DropdownMenuItem>
            <DropdownMenuSeparator />
          </template>
          <DropdownMenuItem @click="emit('invite-members')">
            <Users class="h-4 w-4" />
            {{ t('chat.actions.inviteMembers') }}
          </DropdownMenuItem>
          <DropdownMenuItem
            v-if="canManage"
            @click="emit('settings')"
          >
            <Settings class="h-4 w-4" />
            {{ t('chat.actions.chatSettings') }}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem @click="emit('notification-settings')">
            <Bell class="h-4 w-4" />
            {{ t('chat.actions.notificationSettings') }}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>

    <ScrollArea class="min-h-0 flex-1">
      <div class="p-2">
        <div
          v-for="category in categories"
          :key="category.id"
          class="mb-3 last:mb-0"
        >
          <Collapsible :open="!isCollapsed(category.id)">
            <div
              class="group/cat flex items-center justify-between rounded-md px-1 py-1 transition-colors hover:bg-accent/40"
            >
              <CollapsibleTrigger as-child>
                <button
                  type="button"
                  class="flex flex-1 items-center gap-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground transition-colors hover:text-foreground"
                  @click="toggleCategory(category.id)"
                >
                  <ChevronRight
                    class="h-3 w-3 transition-transform"
                    :class="{ 'rotate-90': !isCollapsed(category.id) }"
                  />
                  <span class="truncate">{{ category.name }}</span>
                </button>
              </CollapsibleTrigger>

              <TooltipProvider v-if="canManage">
                <Tooltip>
                  <TooltipTrigger as-child>
                    <Button
                      variant="ghost"
                      size="icon"
                      class="h-5 w-5 rounded opacity-0 transition-opacity group-hover/cat:opacity-100"
                      @click.stop="emit('create-channel', category.id)"
                    >
                      <Plus class="h-3 w-3" />
                    </Button>
                  </TooltipTrigger>
                  <TooltipContent side="top">
                    <p>{{ t('chat.actions.createChannel') }}</p>
                  </TooltipContent>
                </Tooltip>
              </TooltipProvider>
            </div>

            <CollapsibleContent>
              <div class="mt-0.5 space-y-px">
                <button
                  v-for="channel in category.channels"
                  :key="channel.id"
                  type="button"
                  data-chat-channel-button="true"
                  class="group/ch relative flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors"
                  :class="[
                    activeChannelId === channel.id
                      ? 'bg-accent text-accent-foreground'
                      : 'text-muted-foreground hover:bg-accent/50 hover:text-foreground'
                  ]"
                  @click="selectChannel(channel)"
                >
                  <span
                    v-if="activeChannelId === channel.id"
                    class="absolute inset-y-1 left-0 w-0.5 rounded-full bg-primary"
                    aria-hidden="true"
                  />
                  <component
                    :is="getChannelIcon(channel.type)"
                    class="h-4 w-4 shrink-0"
                    :class="{ 'opacity-60': channel.isMuted }"
                  />
                  <Lock
                    v-if="channel.isPrivate"
                    class="h-3 w-3 shrink-0 text-muted-foreground"
                  />
                  <span
                    class="min-w-0 flex-1 truncate text-sm"
                    :class="{ 'font-medium text-foreground': channel.unreadCount }"
                  >
                    {{ channel.name }}
                  </span>
                  <BellOff
                    v-if="channel.isMuted"
                    class="h-3 w-3 shrink-0 text-muted-foreground"
                  />
                  <span
                    v-if="channel.unreadCount && !channel.isMuted"
                    class="inline-flex h-4 min-w-[16px] items-center justify-center rounded-full bg-primary px-1 text-[10px] font-medium tabular-nums text-primary-foreground"
                  >
                    {{ channel.unreadCount > 99 ? '99+' : channel.unreadCount }}
                  </span>

                  <DropdownMenu>
                    <DropdownMenuTrigger as-child>
                      <Button
                        variant="ghost"
                        size="icon"
                        class="h-5 w-5 rounded opacity-0 transition-opacity group-hover/ch:opacity-100"
                        @click.stop
                      >
                        <Settings class="h-3 w-3" />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end" class="w-44">
                      <DropdownMenuItem
                        @click.stop="emit('toggle-mute', channel.id)"
                      >
                        <component
                          :is="channel.isMuted ? Bell : BellOff"
                          class="h-4 w-4"
                        />
                        {{
                          channel.isMuted
                            ? t('chat.actions.unmuteChannel')
                            : t('chat.actions.muteChannel')
                        }}
                      </DropdownMenuItem>
                      <template v-if="canManage">
                        <DropdownMenuSeparator />
                        <DropdownMenuItem
                          @click.stop="emit('edit-channel', channel)"
                        >
                          <Edit3 class="h-4 w-4" />
                          {{ t('chat.actions.editChannel') }}
                        </DropdownMenuItem>
                        <DropdownMenuItem
                          class="text-destructive focus:text-destructive"
                          @click.stop="emit('delete-channel', channel.id)"
                        >
                          <Trash2 class="h-4 w-4" />
                          {{ t('chat.actions.deleteChannel') }}
                        </DropdownMenuItem>
                      </template>
                    </DropdownMenuContent>
                  </DropdownMenu>
                </button>
              </div>
            </CollapsibleContent>
          </Collapsible>
        </div>
      </div>
    </ScrollArea>

    <div
      class="shrink-0 border-t border-border/60 bg-background/60 p-2 backdrop-blur"
    >
      <div
        class="flex items-center gap-2 rounded-md p-2 transition-colors hover:bg-accent/50"
      >
        <div class="relative shrink-0">
          <div
            class="flex h-8 w-8 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary"
          >
            {{ currentUserInitials.toUpperCase() }}
          </div>
          <span
            class="absolute bottom-0 right-0 h-2.5 w-2.5 rounded-full bg-emerald-500 ring-2 ring-background"
          />
        </div>
        <div class="min-w-0 flex-1">
          <div class="truncate text-sm font-medium">
            {{ currentUserName || t('chat.currentUser.name') }}
          </div>
          <div class="text-xs text-muted-foreground">
            {{ t('chat.status.online') }}
          </div>
        </div>
        <TooltipProvider>
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
              >
                <Settings class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent side="top">
              <p>{{ t('chat.actions.userSettings') }}</p>
            </TooltipContent>
          </Tooltip>
        </TooltipProvider>
      </div>
    </div>
  </div>
</template>
