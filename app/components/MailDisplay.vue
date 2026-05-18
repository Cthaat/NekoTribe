<script lang="ts" setup>
import { computed } from 'vue';
import type { Component } from 'vue';
import {
  AtSign,
  Bell,
  Check,
  ExternalLink,
  Heart,
  MailOpen,
  MessageCircle,
  MoreVertical,
  Repeat2,
  RotateCcw,
  ShieldAlert,
  Trash2,
  UserPlus,
  UserRound
} from 'lucide-vue-next';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import { Separator } from '@/components/ui/separator';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger
} from '@/components/ui/tooltip';
import type { MailItem } from './mail/types';

interface MailDisplayProps {
  mail?: MailItem;
  isTrashView?: boolean;
}

const props = defineProps<MailDisplayProps>();
const emit = defineEmits<{
  (e: 'delete-mail' | 'restore-mail', mailId: string): void;
  (
    e: 'set-read-status',
    payload: { mailId: string; read: boolean }
  ): void;
}>();

const { t, locale } = useAppLocale();

const notificationIcons: Record<string, Component> = {
  like: Heart,
  comment: MessageCircle,
  retweet: Repeat2,
  follow: UserPlus,
  mention: AtSign,
  login_alert: ShieldAlert,
  system: Bell
};

const notificationIcon = computed<Component>(() => {
  const type = props.mail?.type ?? '';
  return notificationIcons[type] ?? Bell;
});

const formattedDate = computed(() => {
  if (!props.mail?.date) return '';

  return new Date(props.mail.date).toLocaleString(
    locale.value === 'zh' ? 'zh-CN' : 'en-US',
    {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    }
  );
});

const priorityBadgeVariant = computed(() =>
  props.mail?.priority === 'high' ||
  props.mail?.priority === 'urgent'
    ? 'destructive'
    : 'outline'
);

function initials(value: string): string {
  return (value || 'NT').substring(0, 2).toUpperCase();
}

function toggleReadStatus() {
  if (!props.mail) return;
  emit('set-read-status', {
    mailId: props.mail.id,
    read: !props.mail.read
  });
}
</script>

<template>
  <div class="flex h-full flex-col">
    <div class="flex items-center p-2">
      <div v-if="mail" class="flex items-center gap-2">
        <Tooltip v-if="mail.href">
          <TooltipTrigger as-child>
            <Button as-child variant="ghost" size="icon">
              <NuxtLink :to="mail.href">
                <ExternalLink class="size-4" />
                <span class="sr-only">{{
                  mail.primaryActionLabel
                }}</span>
              </NuxtLink>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            mail.primaryActionLabel
          }}</TooltipContent>
        </Tooltip>

        <Tooltip v-if="mail.actorHref">
          <TooltipTrigger as-child>
            <Button as-child variant="ghost" size="icon">
              <NuxtLink :to="mail.actorHref">
                <UserRound class="size-4" />
                <span class="sr-only">{{
                  t('mail.display.viewActor')
                }}</span>
              </NuxtLink>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.viewActor')
          }}</TooltipContent>
        </Tooltip>

        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              @click.stop="toggleReadStatus"
            >
              <Check v-if="!mail.read" class="size-4" />
              <MailOpen v-else class="size-4" />
              <span class="sr-only">
                {{
                  mail.read
                    ? t('mail.display.markAsUnread')
                    : t('mail.display.markAsRead')
                }}
              </span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>
            {{
              mail.read
                ? t('mail.display.markAsUnread')
                : t('mail.display.markAsRead')
            }}
          </TooltipContent>
        </Tooltip>

        <Tooltip v-if="!isTrashView">
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              @click.stop="emit('delete-mail', mail.id)"
            >
              <Trash2 class="size-4" />
              <span class="sr-only">{{
                t('mail.display.moveToTrash')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.moveToTrash')
          }}</TooltipContent>
        </Tooltip>

        <Tooltip v-else>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              @click.stop="emit('restore-mail', mail.id)"
            >
              <RotateCcw class="size-4" />
              <span class="sr-only">{{
                t('mail.display.restore')
              }}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent>{{
            t('mail.display.restoreFromTrash')
          }}</TooltipContent>
        </Tooltip>
      </div>

      <div v-if="mail" class="ml-auto">
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button variant="ghost" size="icon">
              <MoreVertical class="size-4" />
              <span class="sr-only">{{
                t('mail.display.more')
              }}</span>
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem
              v-if="mail.href"
              as-child
            >
              <NuxtLink :to="mail.href">
                {{ mail.primaryActionLabel }}
              </NuxtLink>
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="mail.actorHref"
              as-child
            >
              <NuxtLink :to="mail.actorHref">
                {{ t('mail.display.viewActor') }}
              </NuxtLink>
            </DropdownMenuItem>
            <DropdownMenuItem @click="toggleReadStatus">
              {{
                mail.read
                  ? t('mail.display.markAsUnread')
                  : t('mail.display.markAsRead')
              }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>

    <Separator />

    <div v-if="mail" class="min-h-0 flex-1 overflow-auto">
      <div class="flex items-start gap-4 p-4">
        <Avatar class="size-11 shrink-0">
          <AvatarImage :src="mail.avatar" :alt="mail.name" />
          <AvatarFallback>{{ initials(mail.name) }}</AvatarFallback>
        </Avatar>

        <div class="min-w-0 flex-1 space-y-2">
          <div class="flex flex-wrap items-center gap-2">
            <component
              :is="notificationIcon"
              class="size-4 text-muted-foreground"
            />
            <div class="min-w-0 truncate font-semibold">
              {{ mail.name }}
            </div>
            <Badge variant="secondary">
              {{ mail.typeLabel }}
            </Badge>
            <Badge
              v-if="mail.priority !== 'normal'"
              :variant="priorityBadgeVariant"
            >
              {{ mail.priorityLabel }}
            </Badge>
            <span
              v-if="!mail.read"
              class="h-2 w-2 rounded-full bg-blue-600"
            />
          </div>

          <div class="text-sm font-medium">
            {{ mail.subject }}
          </div>

          <div class="text-xs text-muted-foreground">
            {{ formattedDate }}
          </div>
        </div>
      </div>

      <Separator />

      <div class="space-y-4 p-4">
        <p class="whitespace-pre-wrap text-sm leading-6">
          {{ mail.text }}
        </p>

        <div
          v-if="mail.primaryPreview"
          class="rounded-lg border bg-muted/30 p-3"
        >
          <div
            class="mb-2 flex flex-wrap items-center justify-between gap-2"
          >
            <div class="text-sm font-medium">
              {{ mail.primaryPreview.title }}
            </div>
            <Button
              v-if="mail.primaryPreview.to"
              as-child
              variant="link"
              size="sm"
              class="h-auto p-0"
            >
              <NuxtLink :to="mail.primaryPreview.to">
                {{ t('mail.display.openRelated') }}
              </NuxtLink>
            </Button>
          </div>
          <p
            class="whitespace-pre-wrap break-words text-sm text-muted-foreground"
          >
            {{ mail.primaryPreview.text }}
          </p>
        </div>

        <div
          v-if="mail.secondaryPreview"
          class="rounded-lg border bg-background p-3"
        >
          <div
            class="mb-2 flex flex-wrap items-center justify-between gap-2"
          >
            <div class="text-sm font-medium">
              {{ mail.secondaryPreview.title }}
            </div>
            <Button
              v-if="mail.secondaryPreview.to"
              as-child
              variant="link"
              size="sm"
              class="h-auto p-0"
            >
              <NuxtLink :to="mail.secondaryPreview.to">
                {{ t('mail.display.openRelated') }}
              </NuxtLink>
            </Button>
          </div>
          <p
            class="whitespace-pre-wrap break-words text-sm text-muted-foreground"
          >
            {{ mail.secondaryPreview.text }}
          </p>
        </div>

        <div class="flex flex-wrap gap-2">
          <Button
            v-if="mail.href"
            as-child
            size="sm"
          >
            <NuxtLink :to="mail.href">
              <ExternalLink class="size-4" />
              {{ mail.primaryActionLabel }}
            </NuxtLink>
          </Button>
          <Button
            v-if="mail.actorHref"
            as-child
            variant="outline"
            size="sm"
          >
            <NuxtLink :to="mail.actorHref">
              <UserRound class="size-4" />
              {{ t('mail.display.viewActor') }}
            </NuxtLink>
          </Button>
        </div>

        <div
          v-if="mail.details.length > 0"
          class="grid gap-2 rounded-lg border bg-muted/20 p-3 text-sm"
        >
          <div
            v-for="detail in mail.details"
            :key="detail.label"
            class="grid gap-1 sm:grid-cols-[9rem_minmax(0,1fr)]"
          >
            <div class="text-muted-foreground">
              {{ detail.label }}
            </div>
            <div class="min-w-0 break-words">
              {{ detail.value }}
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-else
      class="p-8 text-center text-muted-foreground"
    >
      {{ t('mail.display.noSelection') }}
    </div>
  </div>
</template>
