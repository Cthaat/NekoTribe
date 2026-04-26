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
  VolumeX
} from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
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

// 成员类型定义
export interface ChatMember {
  id: number;
  username: string;
  nickname: string;
  avatar: string;
  role: 'owner' | 'admin' | 'member';
  status: 'online' | 'idle' | 'dnd' | 'offline';
  statusText?: string;
  isInVoice?: boolean;
  isMuted?: boolean;
  isDeafened?: boolean;
}

const props = defineProps<{
  members: ChatMember[];
  canManage?: boolean;
}>();

const emit = defineEmits<{
  (e: 'message', member: ChatMember): void;
  (e: 'kick', memberId: number): void;
  (e: 'ban', memberId: number): void;
  (e: 'view-profile', member: ChatMember): void;
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
      return 'bg-green-500';
    case 'idle':
      return 'bg-yellow-500';
    case 'dnd':
      return 'bg-red-500';
    case 'offline':
      return 'bg-gray-400';
    default:
      return 'bg-gray-400';
  }
};

// 获取状态文本
const getStatusText = (status: ChatMember['status']) => {
  switch (status) {
    case 'online':
      return '在线';
    case 'idle':
      return '离开';
    case 'dnd':
      return '请勿打扰';
    case 'offline':
      return '离线';
    default:
      return '离线';
  }
};

// 获取角色图标
const getRoleIcon = (role: ChatMember['role']) => {
  switch (role) {
    case 'owner':
      return Crown;
    case 'admin':
      return Shield;
    default:
      return null;
  }
};

// 获取角色颜色
const getRoleColor = (role: ChatMember['role']) => {
  switch (role) {
    case 'owner':
      return 'text-amber-500';
    case 'admin':
      return 'text-blue-500';
    default:
      return '';
  }
};
</script>

<template>
  <div
    class="flex flex-col h-full bg-muted/30 border-l w-60"
  >
    <!-- 搜索框 -->
    <div class="p-3 border-b">
      <div class="relative">
        <Search
          class="absolute left-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground"
        />
        <Input
          v-model="searchQuery"
          placeholder="搜索成员"
          class="pl-8 h-8 text-sm"
        />
      </div>
    </div>

    <!-- 成员列表 -->
    <div class="flex-1 overflow-y-auto py-2">
      <!-- 在线成员 -->
      <Collapsible
        v-model:open="isOnlineExpanded"
        class="mb-2"
      >
        <CollapsibleTrigger
          class="flex items-center justify-between w-full px-3 py-1 text-xs font-semibold text-muted-foreground uppercase tracking-wide hover:text-foreground"
        >
          <span>在线 — {{ onlineMembers.length }}</span>
        </CollapsibleTrigger>
        <CollapsibleContent>
          <div class="px-2 space-y-0.5">
            <div
              v-for="member in onlineMembers"
              :key="member.id"
              class="group flex items-center gap-2 p-2 rounded-md hover:bg-muted/50 cursor-pointer transition-colors"
              @click="emit('view-profile', member)"
            >
              <!-- 头像 -->
              <div class="relative flex-shrink-0">
                <Avatar class="h-8 w-8">
                  <AvatarImage
                    :src="member.avatar"
                    :alt="member.nickname"
                  />
                  <AvatarFallback>{{
                    member.nickname.slice(0, 2)
                  }}</AvatarFallback>
                </Avatar>
                <div
                  class="absolute bottom-0 right-0 h-3 w-3 rounded-full border-2 border-background"
                  :class="getStatusColor(member.status)"
                />
              </div>

              <!-- 用户信息 -->
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-1">
                  <!-- 角色图标 -->
                  <component
                    v-if="getRoleIcon(member.role)"
                    :is="getRoleIcon(member.role)"
                    class="h-3 w-3 flex-shrink-0"
                    :class="getRoleColor(member.role)"
                  />
                  <span
                    class="text-sm font-medium truncate"
                    :class="getRoleColor(member.role)"
                  >
                    {{ member.nickname }}
                  </span>
                </div>
                <div
                  v-if="member.statusText"
                  class="text-xs text-muted-foreground truncate"
                >
                  {{ member.statusText }}
                </div>
              </div>

              <!-- 语音状态 -->
              <div
                v-if="member.isInVoice"
                class="flex items-center gap-0.5"
              >
                <component
                  :is="member.isMuted ? VolumeX : Volume2"
                  class="h-3 w-3 text-muted-foreground"
                />
              </div>

              <!-- 操作按钮 -->
              <div
                class="opacity-0 group-hover:opacity-100 transition-opacity"
              >
                <DropdownMenu>
                  <DropdownMenuTrigger as-child>
                    <Button
                      variant="ghost"
                      size="sm"
                      class="h-6 w-6 p-0"
                      @click.stop
                    >
                      <MoreHorizontal class="h-4 w-4" />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuItem
                      @click.stop="emit('message', member)"
                    >
                      <MessageSquare class="mr-2 h-4 w-4" />
                      发送消息
                    </DropdownMenuItem>
                    <template
                      v-if="
                        canManage &&
                        member.role === 'member'
                      "
                    >
                      <DropdownMenuSeparator />
                      <DropdownMenuItem
                        @click.stop="
                          emit('kick', member.id)
                        "
                      >
                        <UserMinus class="mr-2 h-4 w-4" />
                        踢出群组
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        class="text-destructive focus:text-destructive"
                        @click.stop="emit('ban', member.id)"
                      >
                        <Ban class="mr-2 h-4 w-4" />
                        封禁用户
                      </DropdownMenuItem>
                    </template>
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>
            </div>

            <div
              v-if="onlineMembers.length === 0"
              class="text-xs text-muted-foreground text-center py-4"
            >
              暂无在线成员
            </div>
          </div>
        </CollapsibleContent>
      </Collapsible>

      <!-- 离线成员 -->
      <Collapsible v-model:open="isOfflineExpanded">
        <CollapsibleTrigger
          class="flex items-center justify-between w-full px-3 py-1 text-xs font-semibold text-muted-foreground uppercase tracking-wide hover:text-foreground"
        >
          <span>离线 — {{ offlineMembers.length }}</span>
        </CollapsibleTrigger>
        <CollapsibleContent>
          <div class="px-2 space-y-0.5">
            <div
              v-for="member in offlineMembers"
              :key="member.id"
              class="group flex items-center gap-2 p-2 rounded-md hover:bg-muted/50 cursor-pointer transition-colors opacity-60"
              @click="emit('view-profile', member)"
            >
              <!-- 头像 -->
              <div class="relative flex-shrink-0">
                <Avatar class="h-8 w-8 grayscale">
                  <AvatarImage
                    :src="member.avatar"
                    :alt="member.nickname"
                  />
                  <AvatarFallback>{{
                    member.nickname.slice(0, 2)
                  }}</AvatarFallback>
                </Avatar>
                <div
                  class="absolute bottom-0 right-0 h-3 w-3 rounded-full border-2 border-background bg-gray-400"
                />
              </div>

              <!-- 用户信息 -->
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-1">
                  <component
                    v-if="getRoleIcon(member.role)"
                    :is="getRoleIcon(member.role)"
                    class="h-3 w-3 flex-shrink-0"
                    :class="getRoleColor(member.role)"
                  />
                  <span
                    class="text-sm font-medium truncate"
                  >
                    {{ member.nickname }}
                  </span>
                </div>
              </div>

              <!-- 操作按钮 -->
              <div
                class="opacity-0 group-hover:opacity-100 transition-opacity"
              >
                <DropdownMenu>
                  <DropdownMenuTrigger as-child>
                    <Button
                      variant="ghost"
                      size="sm"
                      class="h-6 w-6 p-0"
                      @click.stop
                    >
                      <MoreHorizontal class="h-4 w-4" />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuItem
                      @click.stop="emit('message', member)"
                    >
                      <MessageSquare class="mr-2 h-4 w-4" />
                      发送消息
                    </DropdownMenuItem>
                    <template
                      v-if="
                        canManage &&
                        member.role === 'member'
                      "
                    >
                      <DropdownMenuSeparator />
                      <DropdownMenuItem
                        @click.stop="
                          emit('kick', member.id)
                        "
                      >
                        <UserMinus class="mr-2 h-4 w-4" />
                        踢出群组
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        class="text-destructive focus:text-destructive"
                        @click.stop="emit('ban', member.id)"
                      >
                        <Ban class="mr-2 h-4 w-4" />
                        封禁用户
                      </DropdownMenuItem>
                    </template>
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>
            </div>

            <div
              v-if="offlineMembers.length === 0"
              class="text-xs text-muted-foreground text-center py-4"
            >
              暂无离线成员
            </div>
          </div>
        </CollapsibleContent>
      </Collapsible>
    </div>
  </div>
</template>
