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
import type { GroupMember } from '@/types/groups';

export type { GroupMember } from '@/types/groups';
const { t, locale } = useAppLocale();

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
    case 'moderator':
      return Shield;
    default:
      return User;
  }
});

// 获取角色文本
const roleText = computed(() => {
  switch (props.member.role) {
    case 'owner':
      return t('groups.detail.owner');
    case 'admin':
    case 'moderator':
      return t('groups.member.roles.admin');
    default:
      return t('groups.member.roles.member');
  }
});

// 获取角色徽章变体
const roleBadgeVariant = computed(() => {
  switch (props.member.role) {
    case 'owner':
      return 'default';
    case 'admin':
    case 'moderator':
      return 'secondary';
    default:
      return 'outline';
  }
});

// 格式化时间
const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  return date.toLocaleDateString(locale.value === 'zh' ? 'zh-CN' : 'en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric'
  });
};

// 处理操作
const handleRemove = () => {
  emit('remove', props.member.id);
  toast.success(t('groups.member.feedback.removed'));
};

const handlePromote = () => {
  emit('promote', props.member.id);
  toast.success(t('groups.member.feedback.promoted'));
};

const handleDemote = () => {
  emit('demote', props.member.id);
  toast.success(t('groups.member.feedback.demoted'));
};

const handleMute = () => {
  emit('mute', props.member.id);
  toast.success(t('groups.member.feedback.muted'));
};

const handleUnmute = () => {
  emit('unmute', props.member.id);
  toast.success(t('groups.member.feedback.unmuted'));
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
        {{ t('groups.member.joinedAt', { date: formatTime(member.joinedAt) }) }}
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
            {{ t('groups.member.actions.promote') }}
          </DropdownMenuItem>
          <DropdownMenuItem
            v-if="member.role === 'admin'"
            @click="handleDemote"
          >
            <ShieldMinus class="h-4 w-4 mr-2" />
            {{ t('groups.member.actions.demote') }}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            v-if="!member.isMuted"
            @click="handleMute"
          >
            <VolumeX class="h-4 w-4 mr-2" />
            {{ t('groups.member.actions.mute') }}
          </DropdownMenuItem>
          <DropdownMenuItem v-else @click="handleUnmute">
            <Volume2 class="h-4 w-4 mr-2" />
            {{ t('groups.member.actions.unmute') }}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            class="text-destructive"
            @click="handleRemove"
          >
            <UserMinus class="h-4 w-4 mr-2" />
            {{ t('groups.member.actions.remove') }}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  </div>
</template>
