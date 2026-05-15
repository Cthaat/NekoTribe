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
import { Badge } from '@/components/ui/badge';
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
  <div class="flex h-full min-h-0 flex-col overflow-hidden bg-muted/30">
    <!-- 群组头部 -->
    <div
      class="shrink-0 border-b bg-background/50 p-3 backdrop-blur-sm"
    >
      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            class="w-full justify-between font-semibold text-base h-auto py-2"
          >
            <span class="truncate">{{
              groupName || t('chat.groupFallbackName')
            }}</span>
            <ChevronDown
              class="h-4 w-4 flex-shrink-0 ml-2"
            />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent class="w-56" align="start">
          <template v-if="groups?.length">
            <DropdownMenuItem
              v-for="group in groups"
              :key="group.id"
              @click="emit('select-group', group.id)"
            >
              <Check
                class="mr-2 h-4 w-4"
                :class="{
                  'opacity-100': group.id === activeGroupId,
                  'opacity-0': group.id !== activeGroupId
                }"
              />
              <span class="flex-1 truncate">{{ group.name }}</span>
              <Badge
                v-if="group.unreadCount"
                variant="destructive"
                class="ml-2 h-5 min-w-[20px] px-1.5 text-xs"
              >
                {{
                  group.unreadCount > 99
                    ? '99+'
                    : group.unreadCount
                }}
              </Badge>
            </DropdownMenuItem>
            <DropdownMenuSeparator />
          </template>
          <DropdownMenuItem @click="emit('invite-members')">
            <Users class="mr-2 h-4 w-4" />
            {{ t('chat.actions.inviteMembers') }}
          </DropdownMenuItem>
          <DropdownMenuItem
            v-if="canManage"
            @click="emit('settings')"
          >
            <Settings class="mr-2 h-4 w-4" />
            {{ t('chat.actions.chatSettings') }}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem @click="emit('notification-settings')">
            <Bell class="mr-2 h-4 w-4" />
            {{ t('chat.actions.notificationSettings') }}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>

    <!-- 频道列表 -->
    <ScrollArea class="min-h-0 flex-1">
      <div class="py-2">
      <div
        v-for="category in categories"
        :key="category.id"
        class="mb-2"
      >
        <!-- 分类标题 -->
        <Collapsible :open="!isCollapsed(category.id)">
          <div
            class="flex items-center justify-between px-2 py-1 group cursor-pointer"
            @click="toggleCategory(category.id)"
          >
            <CollapsibleTrigger as-child>
              <div
                class="flex items-center gap-1 text-xs font-semibold text-muted-foreground uppercase tracking-wide hover:text-foreground"
              >
                <ChevronRight
                  class="h-3 w-3 transition-transform"
                  :class="{
                    'rotate-90': !isCollapsed(category.id)
                  }"
                />
                {{ category.name }}
              </div>
            </CollapsibleTrigger>

            <TooltipProvider v-if="canManage">
              <Tooltip>
                <TooltipTrigger as-child>
                  <Button
                    variant="ghost"
                    size="sm"
                    class="h-5 w-5 p-0 opacity-0 group-hover:opacity-100 transition-opacity"
                    @click.stop="
                      emit('create-channel', category.id)
                    "
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
            <!-- 频道列表 -->
            <div class="space-y-0.5 px-2">
              <div
                v-for="channel in category.channels"
                :key="channel.id"
                class="group flex items-center gap-2 px-2 py-1.5 rounded-md cursor-pointer transition-colors"
                :class="[
                  activeChannelId === channel.id
                    ? 'bg-muted text-foreground'
                    : 'text-muted-foreground hover:bg-muted/50 hover:text-foreground'
                ]"
                @click="selectChannel(channel)"
              >
                <!-- 频道图标 -->
                <component
                  :is="getChannelIcon(channel.type)"
                  class="h-4 w-4 flex-shrink-0"
                  :class="{ 'opacity-60': channel.isMuted }"
                />

                <!-- 私密标识 -->
                <Lock
                  v-if="channel.isPrivate"
                  class="h-3 w-3 flex-shrink-0 text-muted-foreground"
                />

                <!-- 频道名称 -->
                <span
                  class="flex-1 truncate text-sm"
                  :class="{
                    'font-medium': channel.unreadCount
                  }"
                >
                  {{ channel.name }}
                </span>

                <!-- 静音标识 -->
                <BellOff
                  v-if="channel.isMuted"
                  class="h-3 w-3 flex-shrink-0 text-muted-foreground"
                />

                <!-- 未读计数 -->
                <Badge
                  v-if="
                    channel.unreadCount && !channel.isMuted
                  "
                  variant="destructive"
                  class="h-5 min-w-[20px] px-1.5 text-xs"
                >
                  {{
                    channel.unreadCount > 99
                      ? '99+'
                      : channel.unreadCount
                  }}
                </Badge>

                <!-- 频道操作（悬浮显示） -->
                <div
                  class="flex items-center gap-0.5 opacity-0 group-hover:opacity-100 transition-opacity"
                >
                  <DropdownMenu>
                    <DropdownMenuTrigger as-child>
                      <Button
                        variant="ghost"
                        size="sm"
                        class="h-5 w-5 p-0"
                        @click.stop
                      >
                        <Settings class="h-3 w-3" />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuItem
                        @click.stop="
                          emit('toggle-mute', channel.id)
                        "
                      >
                        <component
                          :is="
                            channel.isMuted ? Bell : BellOff
                          "
                          class="mr-2 h-4 w-4"
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
                          @click.stop="
                            emit('edit-channel', channel)
                          "
                        >
                          <Edit3 class="mr-2 h-4 w-4" />
                          {{ t('chat.actions.editChannel') }}
                        </DropdownMenuItem>
                        <DropdownMenuItem
                          class="text-destructive focus:text-destructive"
                          @click.stop="
                            emit(
                              'delete-channel',
                              channel.id
                            )
                          "
                        >
                          <Trash2 class="mr-2 h-4 w-4" />
                          {{ t('chat.actions.deleteChannel') }}
                        </DropdownMenuItem>
                      </template>
                    </DropdownMenuContent>
                  </DropdownMenu>
                </div>
              </div>
            </div>
          </CollapsibleContent>
        </Collapsible>
      </div>
      </div>
    </ScrollArea>

    <!-- 用户信息栏 -->
    <div
      class="shrink-0 border-t bg-background/50 p-2 backdrop-blur-sm"
    >
      <div
        class="flex items-center gap-2 p-2 rounded-md hover:bg-muted transition-colors cursor-pointer"
      >
        <div class="relative">
          <div
            class="h-8 w-8 rounded-full bg-primary/20 flex items-center justify-center"
          >
            <span class="text-sm font-medium">{{ currentUserInitials }}</span>
          </div>
          <div
            class="absolute bottom-0 right-0 h-3 w-3 bg-green-500 rounded-full border-2 border-background"
          />
        </div>
        <div class="flex-1 min-w-0">
          <div class="text-sm font-medium truncate">
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
                size="sm"
                class="h-8 w-8 p-0"
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
