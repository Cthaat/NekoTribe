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
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
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

const priorityBadgeClass = computed(() => {
  const priority = props.mail?.priority;
  if (priority === 'urgent') {
    return 'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300';
  }
  if (priority === 'high') {
    return 'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300';
  }
  return 'border-border/60 bg-muted/40 text-muted-foreground';
});

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
  <div class="flex h-full flex-col bg-background">
    <div
      class="flex h-12 shrink-0 items-center gap-1 border-b border-border/60 bg-background/60 px-3 backdrop-blur"
    >
      <template v-if="mail">
        <Tooltip v-if="mail.href">
          <TooltipTrigger as-child>
            <Button
              as-child
              variant="ghost"
              size="icon"
              class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
            >
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
            <Button
              as-child
              variant="ghost"
              size="icon"
              class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
            >
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
              class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
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
              class="h-8 w-8 rounded-md text-muted-foreground hover:text-destructive"
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
              class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
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

        <div class="ml-auto">
          <DropdownMenu>
            <DropdownMenuTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                class="h-8 w-8 rounded-md text-muted-foreground hover:text-foreground"
              >
                <MoreVertical class="size-4" />
                <span class="sr-only">{{
                  t('mail.display.more')
                }}</span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" class="w-48">
              <DropdownMenuItem
                v-if="mail.href"
                as-child
              >
                <NuxtLink :to="mail.href">
                  <ExternalLink class="h-4 w-4" />
                  {{ mail.primaryActionLabel }}
                </NuxtLink>
              </DropdownMenuItem>
              <DropdownMenuItem
                v-if="mail.actorHref"
                as-child
              >
                <NuxtLink :to="mail.actorHref">
                  <UserRound class="h-4 w-4" />
                  {{ t('mail.display.viewActor') }}
                </NuxtLink>
              </DropdownMenuItem>
              <DropdownMenuItem @click="toggleReadStatus">
                <Check v-if="!mail.read" class="h-4 w-4" />
                <MailOpen v-else class="h-4 w-4" />
                {{
                  mail.read
                    ? t('mail.display.markAsUnread')
                    : t('mail.display.markAsRead')
                }}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </template>
    </div>

    <div v-if="mail" class="min-h-0 flex-1 overflow-auto">
      <div class="flex items-start gap-4 border-b border-border/60 p-4">
        <Avatar class="size-11 shrink-0 ring-1 ring-border">
          <AvatarImage :src="mail.avatar" :alt="mail.name" />
          <AvatarFallback class="text-sm">{{ initials(mail.name) }}</AvatarFallback>
        </Avatar>

        <div class="min-w-0 flex-1 space-y-1.5">
          <div class="flex flex-wrap items-center gap-2">
            <component
              :is="notificationIcon"
              class="size-4 text-muted-foreground"
            />
            <span class="min-w-0 truncate text-sm font-semibold">
              {{ mail.name }}
            </span>
            <span
              class="inline-flex items-center rounded-full border border-border/60 bg-muted/40 px-1.5 py-0 text-[10px] font-medium text-muted-foreground"
            >
              {{ mail.typeLabel }}
            </span>
            <span
              v-if="mail.priority !== 'normal'"
              :class="[
                'inline-flex items-center rounded-full border px-1.5 py-0 text-[10px] font-medium',
                priorityBadgeClass
              ]"
            >
              {{ mail.priorityLabel }}
            </span>
            <span
              v-if="!mail.read"
              class="h-1.5 w-1.5 rounded-full bg-primary"
              aria-hidden="true"
            />
          </div>

          <div class="text-sm font-medium tracking-tight text-foreground">
            {{ mail.subject }}
          </div>

          <div class="text-[11px] tabular-nums text-muted-foreground">
            {{ formattedDate }}
          </div>
        </div>
      </div>

      <div class="space-y-4 p-4">
        <p class="whitespace-pre-wrap text-sm leading-6 text-foreground">
          {{ mail.text }}
        </p>

        <div
          v-if="mail.primaryPreview"
          class="rounded-lg border border-border/60 bg-muted/30 p-3"
        >
          <div
            class="mb-1.5 flex flex-wrap items-center justify-between gap-2"
          >
            <div class="text-sm font-medium">
              {{ mail.primaryPreview.title }}
            </div>
            <Button
              v-if="mail.primaryPreview.to"
              as-child
              variant="link"
              size="sm"
              class="h-auto gap-1 p-0 text-xs"
            >
              <NuxtLink :to="mail.primaryPreview.to">
                {{ t('mail.display.openRelated') }}
                <ExternalLink class="h-3 w-3" />
              </NuxtLink>
            </Button>
          </div>
          <p
            class="whitespace-pre-wrap break-words text-sm leading-relaxed text-muted-foreground"
          >
            {{ mail.primaryPreview.text }}
          </p>
        </div>

        <div
          v-if="mail.secondaryPreview"
          class="rounded-lg border border-border/60 bg-card p-3"
        >
          <div
            class="mb-1.5 flex flex-wrap items-center justify-between gap-2"
          >
            <div class="text-sm font-medium">
              {{ mail.secondaryPreview.title }}
            </div>
            <Button
              v-if="mail.secondaryPreview.to"
              as-child
              variant="link"
              size="sm"
              class="h-auto gap-1 p-0 text-xs"
            >
              <NuxtLink :to="mail.secondaryPreview.to">
                {{ t('mail.display.openRelated') }}
                <ExternalLink class="h-3 w-3" />
              </NuxtLink>
            </Button>
          </div>
          <p
            class="whitespace-pre-wrap break-words text-sm leading-relaxed text-muted-foreground"
          >
            {{ mail.secondaryPreview.text }}
          </p>
        </div>

        <div class="flex flex-wrap gap-2">
          <Button
            v-if="mail.href"
            as-child
            size="sm"
            class="h-8 rounded-md shadow-xs"
          >
            <NuxtLink :to="mail.href">
              <ExternalLink class="size-3.5" />
              {{ mail.primaryActionLabel }}
            </NuxtLink>
          </Button>
          <Button
            v-if="mail.actorHref"
            as-child
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
          >
            <NuxtLink :to="mail.actorHref">
              <UserRound class="size-3.5" />
              {{ t('mail.display.viewActor') }}
            </NuxtLink>
          </Button>
        </div>

        <div
          v-if="mail.details.length > 0"
          class="rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <dl class="grid gap-2 text-sm">
            <div
              v-for="detail in mail.details"
              :key="detail.label"
              class="grid gap-1 sm:grid-cols-[9rem_minmax(0,1fr)]"
            >
              <dt class="text-xs font-medium text-muted-foreground">
                {{ detail.label }}
              </dt>
              <dd class="min-w-0 break-words text-sm text-foreground">
                {{ detail.value }}
              </dd>
            </div>
          </dl>
        </div>
      </div>
    </div>

    <div
      v-else
      class="flex flex-1 items-center justify-center p-8"
    >
      <div
        class="flex max-w-[18rem] flex-col items-center gap-3 rounded-xl border border-dashed border-border/60 bg-muted/10 px-4 py-8 text-center"
      >
        <div
          class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
        >
          <MailOpen class="h-5 w-5 text-muted-foreground" />
        </div>
        <p class="text-sm text-muted-foreground">
          {{ t('mail.display.noSelection') }}
        </p>
      </div>
    </div>
  </div>
</template>
