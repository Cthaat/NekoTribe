<script setup lang="ts">
import { computed } from 'vue';
import {
  Crown,
  Shield,
  User,
  MoreHorizontal,
  UserMinus,
  ShieldPlus,
  ShieldMinus,
  VolumeX,
  Volume2
} from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import { toast } from 'vue-sonner';

// 成员类型定义
export interface GroupMember {
  id: number;
  userId: number;
  username: string;
  nickname: string;
  avatar: string;
  role: 'owner' | 'admin' | 'member';
  joinedAt: string;
  isMuted?: boolean;
  mutedUntil?: string;
  lastActiveAt?: string;
}

const props = defineProps<{
  member: GroupMember;
  canManage?: boolean;
  isCurrentUser?: boolean;
}>();

const emit = defineEmits<{
  (e: 'remove', memberId: number): void;
  (e: 'promote', memberId: number): void;
  (e: 'demote', memberId: number): void;
  (e: 'mute', memberId: number): void;
  (e: 'unmute', memberId: number): void;
  (e: 'view-profile', userId: number): void;
}>();

// 获取角色图标
const roleIcon = computed(() => {
  switch (props.member.role) {
    case 'owner':
      return Crown;
    case 'admin':
      return Shield;
    default:
      return User;
  }
});

// 获取角色文本
const roleText = computed(() => {
  switch (props.member.role) {
    case 'owner':
      return '群主';
    case 'admin':
      return '管理员';
    default:
      return '成员';
  }
});

// 获取角色徽章变体
const roleBadgeVariant = computed(() => {
  switch (props.member.role) {
    case 'owner':
      return 'default';
    case 'admin':
      return 'secondary';
    default:
      return 'outline';
  }
});

// 格式化时间
const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  return date.toLocaleDateString('zh-CN', {
    year: 'numeric',
    month: 'short',
    day: 'numeric'
  });
};

// 处理操作
const handleRemove = () => {
  emit('remove', props.member.id);
  toast.success('成员已移除');
};

const handlePromote = () => {
  emit('promote', props.member.id);
  toast.success('已设为管理员');
};

const handleDemote = () => {
  emit('demote', props.member.id);
  toast.success('已取消管理员');
};

const handleMute = () => {
  emit('mute', props.member.id);
  toast.success('已禁言');
};

const handleUnmute = () => {
  emit('unmute', props.member.id);
  toast.success('已解除禁言');
};

const handleViewProfile = () => {
  emit('view-profile', props.member.userId);
};
</script>

<template>
  <div
    class="flex items-center justify-between p-3 rounded-lg hover:bg-muted/50 transition-colors"
  >
    <!-- 用户信息 -->
    <div
      class="flex items-center gap-3 cursor-pointer"
      @click="handleViewProfile"
    >
      <div class="relative">
        <Avatar class="h-10 w-10">
          <AvatarImage
            :src="member.avatar"
            :alt="member.nickname"
          />
          <AvatarFallback>{{
            member.nickname.charAt(0)
          }}</AvatarFallback>
        </Avatar>
        <!-- 禁言标识 -->
        <div
          v-if="member.isMuted"
          class="absolute -bottom-1 -right-1 bg-destructive text-destructive-foreground rounded-full p-0.5"
        >
          <VolumeX class="h-3 w-3" />
        </div>
      </div>
      <div class="flex flex-col">
        <div class="flex items-center gap-2">
          <span class="font-medium text-sm">{{
            member.nickname
          }}</span>
          <Badge
            :variant="roleBadgeVariant"
            class="gap-1 text-xs"
          >
            <component :is="roleIcon" class="h-3 w-3" />
            {{ roleText }}
          </Badge>
        </div>
        <span class="text-xs text-muted-foreground"
          >@{{ member.username }}</span
        >
      </div>
    </div>

    <!-- 加入时间和操作 -->
    <div class="flex items-center gap-2">
      <span
        class="text-xs text-muted-foreground hidden sm:inline"
      >
        {{ formatTime(member.joinedAt) }} 加入
      </span>

      <!-- 管理操作 -->
      <DropdownMenu
        v-if="
          canManage &&
          !isCurrentUser &&
          member.role !== 'owner'
        "
      >
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            size="icon"
            class="h-8 w-8"
          >
            <MoreHorizontal class="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuItem
            v-if="member.role === 'member'"
            @click="handlePromote"
          >
            <ShieldPlus class="h-4 w-4 mr-2" />
            设为管理员
          </DropdownMenuItem>
          <DropdownMenuItem
            v-if="member.role === 'admin'"
            @click="handleDemote"
          >
            <ShieldMinus class="h-4 w-4 mr-2" />
            取消管理员
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            v-if="!member.isMuted"
            @click="handleMute"
          >
            <VolumeX class="h-4 w-4 mr-2" />
            禁言
          </DropdownMenuItem>
          <DropdownMenuItem v-else @click="handleUnmute">
            <Volume2 class="h-4 w-4 mr-2" />
            解除禁言
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            class="text-destructive"
            @click="handleRemove"
          >
            <UserMinus class="h-4 w-4 mr-2" />
            移出群组
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  </div>
</template>
