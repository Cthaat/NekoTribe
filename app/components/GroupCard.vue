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

export type { Group } from '@/types/groups';

const props = defineProps<{
  group: Group;
}>();
const { t } = useAppLocale();

const emit = defineEmits<{
  (e: 'join', id: number): void;
  (e: 'leave', id: number): void;
  (e: 'view-detail', group: Group): void;
  (e: 'settings', id: number): void;
}>();

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
  if (props.group.isMember) {
    emit('leave', props.group.id);
  } else {
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
    class="group/card relative cursor-pointer overflow-hidden rounded-xl border border-border/60 bg-card py-0 shadow-none transition-all duration-200 ease-out hover:-translate-y-0.5 hover:border-border hover:shadow-md"
    @click="handleViewDetail"
  >
    <!-- Cover image with overlay -->
    <div
      class="relative h-28 overflow-hidden bg-gradient-to-br from-primary/15 via-primary/5 to-muted/40"
    >
      <img
        v-if="group.coverImage"
        :src="group.coverImage"
        :alt="group.name"
        class="h-full w-full object-cover transition-transform duration-500 group-hover/card:scale-105"
      />
      <div
        class="pointer-events-none absolute inset-0 bg-gradient-to-t from-background/40 to-transparent"
      />

      <!-- Top right badges -->
      <div class="absolute right-2.5 top-2.5 flex items-center gap-1.5">
        <Badge
          variant="secondary"
          class="gap-1 border border-border/60 bg-background/90 px-2 text-[11px] font-medium backdrop-blur"
        >
          <component :is="privacyIcon" class="h-3 w-3" />
          {{ privacyText }}
        </Badge>
      </div>

      <!-- Owner/Admin badge top left -->
      <div
        v-if="group.isOwner || group.isAdmin"
        class="absolute left-2.5 top-2.5"
      >
        <Badge
          v-if="group.isOwner"
          class="gap-1 border-amber-200/60 bg-amber-100/90 px-2 text-[11px] font-medium text-amber-700 backdrop-blur dark:border-amber-900/40 dark:bg-amber-950/70 dark:text-amber-300"
        >
          <Crown class="h-3 w-3" />
          {{ t('groups.actions.manage') }}
        </Badge>
        <Badge
          v-else-if="group.isAdmin"
          class="gap-1 border border-sky-200/60 bg-sky-100/90 px-2 text-[11px] font-medium text-sky-700 backdrop-blur dark:border-sky-900/40 dark:bg-sky-950/70 dark:text-sky-300"
        >
          <ShieldCheck class="h-3 w-3" />
          Admin
        </Badge>
      </div>
    </div>

    <CardContent class="relative px-5 pb-3 pt-0">
      <!-- Avatar - half overlapping with cover -->
      <div class="relative -mt-9 mb-3 flex items-start justify-between">
        <Avatar
          class="h-16 w-16 shrink-0 rounded-xl border-4 border-card shadow-sm"
        >
          <AvatarImage
            :src="group.avatar"
            :alt="group.name"
            class="rounded-lg"
          />
          <AvatarFallback
            class="rounded-lg bg-gradient-to-br from-primary/15 to-primary/5 text-lg font-semibold uppercase text-primary"
          >
            {{ group.name.charAt(0) }}
          </AvatarFallback>
        </Avatar>

        <DropdownMenu>
          <DropdownMenuTrigger as-child @click.stop>
            <Button
              variant="ghost"
              size="icon"
              class="mt-9 h-8 w-8 rounded-full opacity-70 transition-opacity hover:opacity-100"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" class="w-48">
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

      <!-- Name + description -->
      <div class="space-y-1">
        <h3 class="line-clamp-1 text-base font-semibold leading-tight tracking-tight">
          {{ group.name }}
        </h3>
        <p class="line-clamp-2 min-h-[2.5rem] text-sm leading-relaxed text-muted-foreground">
          {{ group.description }}
        </p>
      </div>

      <!-- Tags -->
      <div
        v-if="
          group.category ||
          (group.tags && group.tags.length > 0)
        "
        class="mt-3 flex flex-wrap gap-1"
      >
        <Badge
          v-if="group.category"
          variant="outline"
          class="rounded-full border-border/60 px-2 py-0 text-[11px] font-normal"
        >
          {{ group.category }}
        </Badge>
        <Badge
          v-for="tag in group.tags?.slice(0, 3)"
          :key="tag"
          variant="secondary"
          class="rounded-full px-2 py-0 text-[11px] font-normal"
        >
          #{{ tag }}
        </Badge>
      </div>

      <!-- Stats row -->
      <div
        class="mt-3 flex items-center gap-3 text-xs text-muted-foreground"
      >
        <div class="flex items-center gap-1.5">
          <Users class="h-3.5 w-3.5" />
          <span class="tabular-nums font-medium text-foreground/70">
            {{ formatMemberCount(group.memberCount) }}
          </span>
          <span>{{ t('groups.stats.members') }}</span>
        </div>
        <span class="text-border">·</span>
        <div class="flex items-center gap-1">
          <span class="tabular-nums font-medium text-foreground/70">
            {{ group.postCount }}
          </span>
          <span>{{ t('groups.stats.posts', { count: group.postCount }) }}</span>
        </div>
      </div>
    </CardContent>

    <CardFooter
      class="border-t border-border/60 bg-muted/30 px-5 py-3"
      @click.stop
    >
      <Button
        v-if="!group.isOwner"
        :variant="group.isMember ? 'outline' : 'default'"
        size="sm"
        class="h-9 w-full rounded-md shadow-xs"
        @click="handleJoinLeave"
      >
        <component
          :is="group.isMember ? LogOut : UserPlus"
          class="h-3.5 w-3.5"
        />
        {{
          group.isMember
            ? t('groups.actions.leave')
            : group.privacy === 'public'
              ? t('groups.actions.join')
              : t('groups.actions.requestJoin')
        }}
      </Button>
      <Button
        v-else
        variant="outline"
        size="sm"
        class="h-9 w-full rounded-md shadow-xs"
        @click="handleSettings"
      >
        <Settings class="h-3.5 w-3.5" />
        {{ t('groups.actions.manage') }}
      </Button>
    </CardFooter>
  </Card>
</template>
