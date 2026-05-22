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
import type { GroupMember } from '@/types/groups';

export type { GroupMember } from '@/types/groups';
const { t, locale } = useAppLocale();

const props = defineProps<{
  member: GroupMember;
  canManage?: boolean;
  disabled?: boolean;
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

const roleText = computed(() => {
  switch (props.member.role) {
    case 'owner':
      return t('groups.detail.owner');
    case 'admin':
      return t('groups.member.roles.admin');
    case 'moderator':
      return t('groups.member.roles.moderator');
    default:
      return t('groups.member.roles.member');
  }
});

const roleBadgeClass = computed(() => {
  switch (props.member.role) {
    case 'owner':
      return 'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300';
    case 'admin':
    case 'moderator':
      return 'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300';
    default:
      return 'border-border/60 bg-muted/40 text-muted-foreground';
  }
});

const fallbackInitial = computed(() => {
  const source = props.member.nickname || props.member.username || '?';
  return source.slice(0, 1).toUpperCase();
});

const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  return date.toLocaleDateString(
    locale.value === 'zh' ? 'zh-CN' : 'en-US',
    {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    }
  );
};

const handleRemove = () => emit('remove', props.member.id);
const handlePromote = () => emit('promote', props.member.id);
const handleDemote = () => emit('demote', props.member.id);
const handleMute = () => emit('mute', props.member.id);
const handleUnmute = () => emit('unmute', props.member.id);
const handleViewProfile = () => emit('view-profile', props.member.userId);
</script>

<template>
  <div
    class="flex items-center justify-between gap-3 rounded-lg p-2 transition-colors hover:bg-muted/40"
  >
    <button
      type="button"
      class="flex min-w-0 flex-1 items-center gap-3 rounded-md text-left"
      @click="handleViewProfile"
    >
      <div class="relative shrink-0">
        <Avatar class="h-10 w-10 ring-1 ring-border">
          <AvatarImage
            :src="member.avatar"
            :alt="member.nickname"
          />
          <AvatarFallback class="text-xs">
            {{ fallbackInitial }}
          </AvatarFallback>
        </Avatar>
        <div
          v-if="member.isMuted"
          class="absolute -bottom-1 -right-1 flex h-4 w-4 items-center justify-center rounded-full bg-destructive text-destructive-foreground ring-2 ring-background"
        >
          <VolumeX class="h-2.5 w-2.5" />
        </div>
      </div>
      <div class="min-w-0 flex-1">
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="truncate text-sm font-medium">
            {{ member.nickname }}
          </span>
          <span
            :class="[
              'inline-flex shrink-0 items-center gap-1 rounded-full border px-1.5 py-0 text-[10px] font-medium',
              roleBadgeClass
            ]"
          >
            <component :is="roleIcon" class="h-2.5 w-2.5" />
            {{ roleText }}
          </span>
        </div>
        <div class="truncate text-xs text-muted-foreground">
          @{{ member.username }}
        </div>
      </div>
    </button>

    <div class="flex shrink-0 items-center gap-2">
      <span class="hidden text-xs text-muted-foreground sm:inline">
        {{ t('groups.member.joinedAt', { date: formatTime(member.joinedAt) }) }}
      </span>

      <DropdownMenu
        v-if="canManage && !isCurrentUser && member.role !== 'owner'"
      >
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            size="icon"
            class="h-8 w-8 rounded-full text-muted-foreground hover:bg-accent"
            :disabled="disabled"
          >
            <MoreHorizontal class="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" class="w-44">
          <DropdownMenuItem
            v-if="member.role === 'member'"
            :disabled="disabled"
            @click="handlePromote"
          >
            <ShieldPlus class="h-4 w-4" />
            {{ t('groups.member.actions.promote') }}
          </DropdownMenuItem>
          <DropdownMenuItem
            v-if="member.role === 'admin'"
            :disabled="disabled"
            @click="handleDemote"
          >
            <ShieldMinus class="h-4 w-4" />
            {{ t('groups.member.actions.demote') }}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            v-if="!member.isMuted"
            :disabled="disabled"
            @click="handleMute"
          >
            <VolumeX class="h-4 w-4" />
            {{ t('groups.member.actions.mute') }}
          </DropdownMenuItem>
          <DropdownMenuItem
            v-else
            :disabled="disabled"
            @click="handleUnmute"
          >
            <Volume2 class="h-4 w-4" />
            {{ t('groups.member.actions.unmute') }}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            class="text-destructive focus:text-destructive"
            :disabled="disabled"
            @click="handleRemove"
          >
            <UserMinus class="h-4 w-4" />
            {{ t('groups.member.actions.remove') }}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  </div>
</template>
