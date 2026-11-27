<script setup lang="ts">
import { computed } from 'vue';
import {
  Users,
  Lock,
  Globe,
  Shield,
  MoreHorizontal,
  UserPlus,
  LogOut,
  Settings,
  Eye,
  Crown,
  ShieldCheck
} from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardFooter
} from '@/components/ui/card';
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
import type { Group } from '@/types/groups';
import { groupMembershipAction } from '@/services/groups';

export type { Group } from '@/types/groups';

const props = defineProps<{
  group: Group;
}>();
const { t } = useAppLocale();
const membershipAction = computed(() => groupMembershipAction(props.group));

const emit = defineEmits<{
  (e: 'join', id: number): void;
  (e: 'leave', id: number): void;
  (e: 'view-detail', group: Group): void;
  (e: 'settings', id: number): void;
}>();

const groupInitial = computed(() => {
  const trimmed = (props.group.name || '').trim();
  return trimmed ? Array.from(trimmed)[0]!.toUpperCase() : 'G';
});

const privacyIcon = computed(() => {
  switch (props.group.privacy) {
    case 'public':
      return Globe;
    case 'private':
      return Lock;
    case 'secret':
      return Shield;
    default:
      return Globe;
  }
});

const privacyText = computed(() => {
  switch (props.group.privacy) {
    case 'public':
      return t('groups.filters.privacy.public');
    case 'private':
      return t('groups.filters.privacy.private');
    case 'secret':
      return t('groups.filters.privacy.secret');
    default:
      return t('groups.filters.privacy.public');
  }
});

const formatMemberCount = (count: number) => {
  if (count >= 10000) {
    return t('groups.number.tenThousand', {
      value: (count / 10000).toFixed(1)
    });
  } else if (count >= 1000) {
    return t('groups.number.thousand', {
      value: (count / 1000).toFixed(1)
    });
  }
  return count.toString();
};

const handleJoinLeave = () => {
  if (membershipAction.value?.event === 'leave') {
    emit('leave', props.group.id);
  } else if (membershipAction.value?.event === 'join') {
    emit('join', props.group.id);
  }
};

const handleViewDetail = () => {
  emit('view-detail', props.group);
};

const handleSettings = () => {
  emit('settings', props.group.id);
};
</script>

<template>
  <Card
    class="group/card relative flex cursor-pointer flex-col overflow-hidden rounded-[20px] border-0 bg-card py-0 shadow-[0_1px_3px_rgba(15,23,42,0.03)] transition-all duration-200 ease-out hover:shadow-[0_2px_10px_rgba(15,23,42,0.05)] dark:shadow-none dark:hover:bg-[#171B21]"
    @click="handleViewDetail"
  >
    <!-- Cover image (rendered only when coverImage is present) -->
    <div
      v-if="group.coverImage"
      class="relative h-[96px] overflow-hidden bg-secondary"
    >
      <img
        :src="group.coverImage"
        :alt="group.name"
        class="h-full w-full object-cover transition-transform duration-300 group-hover/card:scale-[1.03]"
      />

      <div class="absolute right-2.5 top-2.5 flex items-center gap-1.5">
        <Badge
          variant="secondary"
          class="gap-1 border-0 bg-card/88 px-2.5 py-0.5 text-[11px] font-medium text-muted-foreground backdrop-blur-sm"
        >
          <component :is="privacyIcon" class="h-3 w-3" />
          {{ privacyText }}
        </Badge>
      </div>

      <div
        v-if="group.isOwner || group.isAdmin"
        class="absolute left-2.5 top-2.5"
      >
        <Badge
          v-if="group.isOwner"
          variant="secondary"
          class="gap-1 border-0 bg-card/88 px-2.5 py-0.5 text-[11px] font-medium text-foreground backdrop-blur-sm"
        >
          <Crown class="h-3 w-3 text-primary" />
          {{ t('groups.actions.manage') }}
        </Badge>
        <Badge
          v-else-if="group.isAdmin"
          variant="secondary"
          class="gap-1 border-0 bg-card/88 px-2.5 py-0.5 text-[11px] font-medium text-foreground backdrop-blur-sm"
        >
          <ShieldCheck class="h-3 w-3 text-primary" />
          Admin
        </Badge>
      </div>
    </div>

    <CardContent class="relative flex-1 px-4 pt-4 pb-3">
      <div
        v-if="!group.coverImage"
        class="mb-2.5 flex flex-wrap items-center justify-between gap-1.5"
      >
        <div class="flex items-center gap-1.5">
          <Badge
            v-if="group.isOwner"
            variant="secondary"
            class="gap-1 border-0 bg-secondary px-2 py-0.5 text-[11px] font-medium text-foreground"
          >
            <Crown class="h-3 w-3 text-primary" />
            {{ t('groups.actions.manage') }}
          </Badge>
          <Badge
            v-else-if="group.isAdmin"
            variant="secondary"
            class="gap-1 border-0 bg-secondary px-2 py-0.5 text-[11px] font-medium text-foreground"
          >
            <ShieldCheck class="h-3 w-3 text-primary" />
            Admin
          </Badge>
        </div>
        <Badge
          variant="secondary"
          class="ml-auto gap-1 border-0 bg-secondary px-2 py-0.5 text-[11px] font-medium text-muted-foreground"
        >
          <component :is="privacyIcon" class="h-3 w-3" />
          {{ privacyText }}
        </Badge>
      </div>
      <div class="mb-2.5 flex items-center gap-3">
        <Avatar
          class="h-12 w-12 shrink-0 rounded-[14px] border-0 bg-secondary"
        >
          <AvatarImage
            :src="group.avatar"
            :alt="group.name"
            class="rounded-[14px] object-cover"
          />
          <AvatarFallback
            class="rounded-[14px] bg-secondary text-base font-semibold uppercase text-muted-foreground"
          >
            {{ groupInitial }}
          </AvatarFallback>
        </Avatar>

        <div class="min-w-0 flex-1">
          <h3 class="line-clamp-1 text-[15px] font-semibold leading-snug tracking-tight text-foreground">
            {{ group.name }}
          </h3>
          <div class="mt-0.5 flex items-center gap-1.5 text-xs text-[var(--ink-tertiary)]">
            <Users class="h-3.5 w-3.5 shrink-0" />
            <span class="tabular-nums font-medium">
              {{ formatMemberCount(group.memberCount) }}
            </span>
            <span>{{ t('groups.stats.members') }}</span>
            <span>·</span>
            <span class="tabular-nums font-medium">
              {{ t('groups.stats.posts', { count: group.postCount }) }}
            </span>
          </div>
        </div>

        <DropdownMenu>
          <DropdownMenuTrigger as-child @click.stop>
            <Button
              variant="ghost"
              size="icon"
              class="size-8 shrink-0 text-muted-foreground hover:text-foreground"
              :aria-label="t('common.more')"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" class="w-48 rounded-2xl border-0 shadow-md">
            <DropdownMenuItem @click.stop="handleViewDetail">
              <Eye class="mr-2 h-4 w-4" />
              {{ t('groups.actions.viewDetail') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator
              v-if="group.isOwner || group.isAdmin"
            />
            <DropdownMenuItem
              v-if="group.isOwner || group.isAdmin"
              @click.stop="handleSettings"
            >
              <Settings class="mr-2 h-4 w-4" />
              {{ t('groups.actions.settings') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <p v-if="group.description?.trim()" class="line-clamp-2 text-[13.5px] leading-relaxed text-muted-foreground">
        {{ group.description }}
      </p>

      <div
        v-if="group.category || (group.tags && group.tags.length > 0)"
        class="mt-3 flex flex-wrap gap-1.5"
      >
        <Badge
          v-if="group.category"
          variant="secondary"
          class="rounded-full border-0 bg-secondary px-2.5 py-0.5 text-[11px] font-medium text-muted-foreground"
        >
          {{ group.category }}
        </Badge>
        <Badge
          v-for="tag in group.tags?.slice(0, 3)"
          :key="tag"
          variant="secondary"
          class="rounded-full border-0 bg-[var(--primary-soft)] px-2.5 py-0.5 text-[11px] font-medium text-primary"
        >
          #{{ tag }}
        </Badge>
      </div>
    </CardContent>

    <CardFooter
      class="border-0 bg-transparent px-4 pt-0 pb-4"
      @click.stop
    >
      <Button
        v-if="membershipAction"
        variant="ghost"
        size="sm"
        class="pressable h-9 w-full rounded-full font-semibold transition-colors"
        :class="
          membershipAction.event === 'leave'
            ? 'bg-secondary text-secondary-foreground hover:bg-secondary/80'
            : 'bg-[var(--primary-soft)] text-primary hover:bg-primary hover:text-primary-foreground'
        "
        @click="handleJoinLeave"
      >
        <component
          :is="membershipAction.event === 'leave' ? LogOut : UserPlus"
          class="h-3.5 w-3.5"
        />
        {{
          membershipAction.event === 'leave' && group.membershipStatus === 'active'
            ? t('groups.joinedBadge')
            : t(`groups.actions.${membershipAction.label}`)
        }}
      </Button>
      <Button
        v-else-if="group.isOwner"
        variant="ghost"
        size="sm"
        class="pressable h-9 w-full rounded-full bg-secondary font-semibold text-secondary-foreground hover:bg-secondary/80"
        @click="handleSettings"
      >
        <Settings class="h-3.5 w-3.5" />
        {{ t('groups.actions.manage') }}
      </Button>
    </CardFooter>
  </Card>
</template>
