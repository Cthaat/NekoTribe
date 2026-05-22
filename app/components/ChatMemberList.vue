<script setup lang="ts">
import { ref, computed } from 'vue';
import {
  Search,
  Crown,
  Shield,
  MoreHorizontal,
  MessageSquare,
  UserMinus,
  Ban,
  Volume2,
  VolumeX,
  ChevronRight
} from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
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

const { t, locale } = useAppLocale();

// 成员类型定义
export interface ChatMember {
  id: number;
  username: string;
  nickname: string;
  avatar: string;
  role: 'owner' | 'admin' | 'moderator' | 'member';
  status: 'online' | 'idle' | 'dnd' | 'offline';
  statusText?: string;
  lastSeenAt?: string | null;
  isInVoice?: boolean;
  isMuted?: boolean;
  isDeafened?: boolean;
}

const props = defineProps<{
  members: ChatMember[];
  canManage?: boolean;
  currentUserId?: number;
}>();

const emit = defineEmits<{
  (e: 'message' | 'view-profile', member: ChatMember): void;
  (e: 'kick' | 'ban', memberId: number): void;
}>();

// 搜索
const searchQuery = ref('');

// 分组展开状态
const isOnlineExpanded = ref(true);
const isOfflineExpanded = ref(true);

// 过滤成员
const filteredMembers = computed(() => {
  if (!searchQuery.value.trim()) {
    return props.members;
  }
  const query = searchQuery.value.toLowerCase();
  return props.members.filter(
    m =>
      m.nickname.toLowerCase().includes(query) ||
      m.username.toLowerCase().includes(query)
  );
});

// 在线成员
const onlineMembers = computed(() => {
  return filteredMembers.value.filter(
    m => m.status !== 'offline'
  );
});

// 离线成员
const offlineMembers = computed(() => {
  return filteredMembers.value.filter(
    m => m.status === 'offline'
  );
});

// 获取状态颜色
const getStatusColor = (status: ChatMember['status']) => {
  switch (status) {
    case 'online':
      return 'bg-emerald-500';
    case 'idle':
      return 'bg-amber-500';
    case 'dnd':
      return 'bg-rose-500';
    case 'offline':
      return 'bg-muted-foreground/60';
    default:
      return 'bg-muted-foreground/60';
  }
};

const formatLastSeen = (value?: string | null): string => {
  if (!value) return '';
  return new Date(value).toLocaleString(
    locale.value === 'en' ? 'en-US' : 'zh-CN',
    {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    }
  );
};

// 获取角色图标
const getRoleIcon = (role: ChatMember['role']) => {
  switch (role) {
    case 'owner':
      return Crown;
    case 'admin':
    case 'moderator':
      return Shield;
    default:
      return null;
  }
};

// 获取角色颜色
const getRoleColor = (role: ChatMember['role']) => {
  switch (role) {
    case 'owner':
      return 'text-amber-600 dark:text-amber-400';
    case 'admin':
      return 'text-sky-600 dark:text-sky-400';
    case 'moderator':
      return 'text-emerald-600 dark:text-emerald-400';
    default:
      return '';
  }
};
</script>

<template>
  <div
    class="flex h-full min-h-0 w-full shrink-0 flex-col overflow-hidden border-l border-border/60 bg-muted/20 lg:w-60"
  >
    <!-- 搜索框 -->
    <div class="shrink-0 border-b border-border/60 bg-background/60 p-2 backdrop-blur">
      <div class="relative">
        <Search
          class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          v-model="searchQuery"
          :placeholder="t('chat.members.searchPlaceholder')"
          class="h-8 pl-8 text-sm shadow-xs"
        />
      </div>
    </div>

    <!-- 成员列表 -->
    <ScrollArea class="min-h-0 flex-1">
      <div class="p-2">
        <!-- 在线成员 -->
        <Collapsible
          v-model:open="isOnlineExpanded"
          class="mb-3"
        >
          <CollapsibleTrigger
            class="flex w-full items-center gap-1 rounded-md px-1 py-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground transition-colors hover:text-foreground"
          >
            <ChevronRight
              class="h-3 w-3 transition-transform"
              :class="{ 'rotate-90': isOnlineExpanded }"
            />
            <span>
              {{ t('chat.members.onlineCount', { count: onlineMembers.length }) }}
            </span>
          </CollapsibleTrigger>
          <CollapsibleContent>
            <div class="mt-0.5 space-y-px">
              <div
                v-for="member in onlineMembers"
                :key="member.id"
                class="group/mem flex items-center rounded-md transition-colors hover:bg-accent/50"
              >
                <button
                  type="button"
                  class="flex min-w-0 flex-1 items-center gap-2 rounded-md px-2 py-1.5 text-left"
                  @click="emit('view-profile', member)"
                >
                  <div class="relative shrink-0">
                    <Avatar class="h-7 w-7 ring-1 ring-border">
                      <AvatarImage
                        :src="member.avatar"
                        :alt="member.nickname"
                      />
                      <AvatarFallback class="text-[10px]">
                        {{ member.nickname.slice(0, 2) }}
                      </AvatarFallback>
                    </Avatar>
                    <span
                      class="absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full ring-2 ring-background"
                      :class="getStatusColor(member.status)"
                    />
                  </div>

                  <div class="min-w-0 flex-1">
                    <div class="flex min-w-0 items-center gap-1">
                      <component
                        :is="getRoleIcon(member.role)"
                        v-if="getRoleIcon(member.role)"
                        class="h-3 w-3 shrink-0"
                        :class="getRoleColor(member.role)"
                      />
                      <span
                        class="truncate text-sm font-medium"
                        :class="getRoleColor(member.role)"
                      >
                        {{ member.nickname }}
                      </span>
                    </div>
                    <div
                      v-if="member.statusText"
                      class="truncate text-[11px] text-muted-foreground"
                    >
                      {{ member.statusText }}
                    </div>
                  </div>

                  <component
                    v-if="member.isInVoice"
                    :is="member.isMuted ? VolumeX : Volume2"
                    class="h-3 w-3 shrink-0 text-muted-foreground"
                  />
                </button>

                <DropdownMenu>
                  <DropdownMenuTrigger as-child>
                    <Button
                      variant="ghost"
                      size="icon"
                      class="mr-1 h-6 w-6 rounded opacity-0 transition-opacity group-hover/mem:opacity-100"
                      @click.stop
                    >
                      <MoreHorizontal class="h-3.5 w-3.5" />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end" class="w-44">
                    <DropdownMenuItem
                      :disabled="member.id === currentUserId"
                      @click.stop="emit('message', member)"
                    >
                      <MessageSquare class="h-4 w-4" />
                      {{ t('chat.actions.sendMessage') }}
                    </DropdownMenuItem>
                    <template
                      v-if="
                        canManage &&
                        !['owner', 'admin'].includes(member.role)
                      "
                    >
                      <DropdownMenuSeparator />
                      <DropdownMenuItem @click.stop="emit('kick', member.id)">
                        <UserMinus class="h-4 w-4" />
                        {{ t('chat.actions.kick') }}
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        class="text-destructive focus:text-destructive"
                        @click.stop="emit('ban', member.id)"
                      >
                        <Ban class="h-4 w-4" />
                        {{ t('chat.actions.ban') }}
                      </DropdownMenuItem>
                    </template>
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>

              <div
                v-if="onlineMembers.length === 0"
                class="px-2 py-3 text-center text-[11px] text-muted-foreground"
              >
                {{ t('chat.members.noOnline') }}
              </div>
            </div>
          </CollapsibleContent>
        </Collapsible>

        <!-- 离线成员 -->
        <Collapsible v-model:open="isOfflineExpanded">
          <CollapsibleTrigger
            class="flex w-full items-center gap-1 rounded-md px-1 py-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground transition-colors hover:text-foreground"
          >
            <ChevronRight
              class="h-3 w-3 transition-transform"
              :class="{ 'rotate-90': isOfflineExpanded }"
            />
            <span>
              {{ t('chat.members.offlineCount', { count: offlineMembers.length }) }}
            </span>
          </CollapsibleTrigger>
          <CollapsibleContent>
            <div class="mt-0.5 space-y-px">
              <div
                v-for="member in offlineMembers"
                :key="member.id"
                class="group/mem flex items-center rounded-md opacity-60 transition-all hover:bg-accent/50 hover:opacity-100"
              >
                <button
                  type="button"
                  class="flex min-w-0 flex-1 items-center gap-2 rounded-md px-2 py-1.5 text-left"
                  @click="emit('view-profile', member)"
                >
                  <div class="relative shrink-0">
                    <Avatar class="h-7 w-7 ring-1 ring-border grayscale">
                      <AvatarImage
                        :src="member.avatar"
                        :alt="member.nickname"
                      />
                      <AvatarFallback class="text-[10px]">
                        {{ member.nickname.slice(0, 2) }}
                      </AvatarFallback>
                    </Avatar>
                    <span
                      class="absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-muted-foreground/60 ring-2 ring-background"
                    />
                  </div>

                  <div class="min-w-0 flex-1">
                    <div class="flex min-w-0 items-center gap-1">
                      <component
                        :is="getRoleIcon(member.role)"
                        v-if="getRoleIcon(member.role)"
                        class="h-3 w-3 shrink-0"
                        :class="getRoleColor(member.role)"
                      />
                      <span class="truncate text-sm font-medium">
                        {{ member.nickname }}
                      </span>
                    </div>
                    <div
                      v-if="member.lastSeenAt"
                      class="truncate text-[11px] text-muted-foreground"
                    >
                      {{
                        t('chat.status.lastSeen', {
                          time: formatLastSeen(member.lastSeenAt)
                        })
                      }}
                    </div>
                  </div>
                </button>

                <DropdownMenu>
                  <DropdownMenuTrigger as-child>
                    <Button
                      variant="ghost"
                      size="icon"
                      class="mr-1 h-6 w-6 rounded opacity-0 transition-opacity group-hover/mem:opacity-100"
                      @click.stop
                    >
                      <MoreHorizontal class="h-3.5 w-3.5" />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end" class="w-44">
                    <DropdownMenuItem
                      :disabled="member.id === currentUserId"
                      @click.stop="emit('message', member)"
                    >
                      <MessageSquare class="h-4 w-4" />
                      {{ t('chat.actions.sendMessage') }}
                    </DropdownMenuItem>
                    <template
                      v-if="
                        canManage &&
                        !['owner', 'admin'].includes(member.role)
                      "
                    >
                      <DropdownMenuSeparator />
                      <DropdownMenuItem @click.stop="emit('kick', member.id)">
                        <UserMinus class="h-4 w-4" />
                        {{ t('chat.actions.kick') }}
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        class="text-destructive focus:text-destructive"
                        @click.stop="emit('ban', member.id)"
                      >
                        <Ban class="h-4 w-4" />
                        {{ t('chat.actions.ban') }}
                      </DropdownMenuItem>
                    </template>
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>

              <div
                v-if="offlineMembers.length === 0"
                class="px-2 py-3 text-center text-[11px] text-muted-foreground"
              >
                {{ t('chat.members.noOffline') }}
              </div>
            </div>
          </CollapsibleContent>
        </Collapsible>
      </div>
    </ScrollArea>
  </div>
</template>
