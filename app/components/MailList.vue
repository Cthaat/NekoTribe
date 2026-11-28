<script lang="ts" setup>
import {
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch,
  type Component
} from 'vue';
import {
  AtSign,
  Bell,
  Check,
  ChevronDown,
  ChevronUp,
  Heart,
  Info,
  MailOpen,
  MessageCircle,
  MoreHorizontal,
  Repeat2,
  RotateCcw,
  ShieldAlert,
  Trash2,
  UserPlus
} from 'lucide-vue-next';
import UserAvatar from '@/components/UserAvatar.vue';
import { formatFullTime, formatRelativeTime } from '@/utils/relativeTime';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import type { MailItem } from './mail/types';

interface MailListProps {
  items: MailItem[];
  loadMore?: () => void;
  isTrashView?: boolean;
}

const emit = defineEmits<{
  (e: 'read-mail' | 'open-details' | 'delete-mail' | 'restore-mail', mailId: string): void;
  (e: 'set-read-status', payload: { mailId: string; read: boolean }): void;
}>();

const { t, locale } = useAppLocale();
const props = withDefaults(defineProps<MailListProps>(), {
  loadMore: undefined,
  isTrashView: false
});
const selectedMail = defineModel<string>('selectedMail', {
  required: false
});

const localItems = ref<MailItem[]>([]);
const expandedDeviceIds = ref<Set<string>>(new Set());

watch(
  () => props.items,
  items => {
    localItems.value = (items ?? []).map(it => ({ ...it }));
    nextTick(() => {
      if (observer && sentinel.value) {
        try {
          observer.unobserve(sentinel.value);
        } catch {
          // Sentinel may already be detached during rapid updates.
        }
        observer.observe(sentinel.value);
      }
    });
  },
  { immediate: true }
);

const typeBadgeMap: Record<string, { icon: Component; bg: string; fg: string }> = {
  like: { icon: Heart, bg: 'bg-[var(--like)]/12', fg: 'text-[var(--like)]' },
  comment: { icon: MessageCircle, bg: 'bg-primary/12', fg: 'text-primary' },
  reply: { icon: MessageCircle, bg: 'bg-primary/12', fg: 'text-primary' },
  group_comment: { icon: MessageCircle, bg: 'bg-primary/12', fg: 'text-primary' },
  retweet: { icon: Repeat2, bg: 'bg-[var(--repost)]/12', fg: 'text-[var(--repost)]' },
  follow: { icon: UserPlus, bg: 'bg-violet-500/12', fg: 'text-violet-500' },
  mention: { icon: AtSign, bg: 'bg-primary/12', fg: 'text-primary' },
  login_alert: { icon: ShieldAlert, bg: 'bg-secondary', fg: 'text-foreground' },
  system: { icon: Bell, bg: 'bg-secondary', fg: 'text-muted-foreground' }
};

function badgeForType(type: string) {
  return typeBadgeMap[type] ?? { icon: Bell, bg: 'bg-secondary', fg: 'text-muted-foreground' };
}

function toggleDeviceDetails(id: string) {
  const next = new Set(expandedDeviceIds.value);
  if (next.has(id)) {
    next.delete(id);
  } else {
    next.add(id);
  }
  expandedDeviceIds.value = next;
}

const sentinel = ref<HTMLDivElement | null>(null);
let observer: IntersectionObserver | null = null;
let throttling = false;

function reobserveSentinel() {
  if (!observer || !sentinel.value) return;
  try {
    observer.unobserve(sentinel.value);
  } catch {
    // Sentinel may already be removed.
  }
  observer.observe(sentinel.value);
}

function setupObserver() {
  if (!sentinel.value) return;
  observer = new IntersectionObserver(
    entries => {
      const entry = entries[0];
      if (!entry) return;
      if (entry.isIntersecting && props.loadMore && !throttling) {
        throttling = true;
        try {
          props.loadMore();
        } finally {
          setTimeout(() => {
            throttling = false;
            reobserveSentinel();
          }, 600);
        }
      }
    },
    { rootMargin: '0px 0px 200px 0px', threshold: 0 }
  );
  observer.observe(sentinel.value);
}

onMounted(() => setupObserver());
onBeforeUnmount(() => {
  if (observer && sentinel.value) {
    observer.unobserve(sentinel.value);
  }
  observer?.disconnect();
  observer = null;
});

function handleRowClick(item: MailItem) {
  const mailId = String(item.id);
  selectedMail.value = mailId;
  const target = localItems.value.find(m => String(m.id) === mailId);
  if (target) target.read = true;
  if (!item.read) {
    emit('read-mail', mailId);
  }
  if (item.href && !props.isTrashView) {
    navigateTo(item.href);
    return;
  }
  emit('open-details', mailId);
}
</script>

<template>
  <div>
    <TransitionGroup name="w3-list" tag="div" class="relative mx-3 space-y-2.5 py-3 sm:mx-4">
      <article
        v-for="item in localItems"
        :key="item.id"
        class="group relative flex cursor-pointer items-start gap-3 rounded-[18px] bg-card px-4 py-3.5 shadow-[0_1px_3px_rgba(15,23,42,0.03)] transition-colors duration-150 hover:bg-[var(--hover)] dark:shadow-none"
        :class="[
          !item.read ? 'bg-primary/[0.04] dark:bg-primary/[0.08]' : ''
        ]"
        @click="handleRowClick(item)"
      >
        <!-- Left type icon -->
        <div
          class="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full"
          :class="[badgeForType(item.type).bg, badgeForType(item.type).fg]"
        >
          <component :is="badgeForType(item.type).icon" class="size-4" />
        </div>

        <!-- Body -->
        <div class="min-w-0 flex-1">
          <div class="flex items-start justify-between gap-2">
            <div class="flex min-w-0 items-center gap-2">
              <UserAvatar
                v-if="item.actorHref || item.avatar"
                :src="item.avatar"
                :name="item.name"
                :username="item.email"
                :seed="item.actorId ?? item.id"
                size="sm"
                class="pressable shrink-0"
                @click.stop="item.actorHref && navigateTo(item.actorHref)"
              />
              <div class="min-w-0 flex items-center gap-1.5">
                <span
                  v-if="!item.read"
                  class="size-1.5 shrink-0 rounded-full bg-primary"
                  aria-hidden="true"
                />
                <span
                  class="truncate text-[14px] text-foreground"
                  :class="!item.read ? 'font-bold' : 'font-semibold'"
                >
                  {{ item.name }}
                </span>
                <span class="shrink-0 text-xs text-muted-foreground">·</span>
                <time
                  :datetime="item.date"
                  :title="formatFullTime(item.date, locale)"
                  class="shrink-0 text-xs text-muted-foreground"
                >
                  {{ formatRelativeTime(item.date, locale) }}
                </time>
              </div>
            </div>

            <div class="flex shrink-0 items-center gap-0.5" @click.stop>
              <DropdownMenu>
                <DropdownMenuTrigger as-child>
                  <Button
                    variant="ghost"
                    size="icon"
                    class="-mr-1 size-7 rounded-full text-muted-foreground opacity-70 transition-opacity hover:bg-primary/10 hover:text-primary hover:opacity-100"
                    :aria-label="t('mail.display.more')"
                  >
                    <MoreHorizontal class="size-4" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" class="w-48 rounded-2xl p-1.5">
                  <DropdownMenuItem @select="() => { selectedMail = item.id; emit('open-details', item.id); }">
                    <Info class="mr-2 size-4" />
                    <span>{{ item.primaryActionLabel || t('mail.display.more') }}</span>
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    v-if="!isTrashView"
                    @select="emit('set-read-status', { mailId: item.id, read: !item.read })"
                  >
                    <Check v-if="!item.read" class="mr-2 size-4" />
                    <MailOpen v-else class="mr-2 size-4" />
                    <span>{{ item.read ? t('mail.display.markAsUnread') : t('mail.display.markAsRead') }}</span>
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    v-if="!isTrashView"
                    class="text-destructive focus:text-destructive"
                    @select="emit('delete-mail', item.id)"
                  >
                    <Trash2 class="mr-2 size-4" />
                    <span>{{ t('mail.display.moveToTrash') }}</span>
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    v-else
                    @select="emit('restore-mail', item.id)"
                  >
                    <RotateCcw class="mr-2 size-4" />
                    <span>{{ t('mail.display.restore') }}</span>
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          </div>

          <p
            v-if="item.subject && item.subject !== item.name"
            class="mt-1 text-sm text-foreground"
            :class="!item.read ? 'font-semibold' : 'font-medium'"
          >
            {{ item.subject }}
          </p>

          <p class="mt-0.5 text-sm leading-[1.45] text-muted-foreground">
            {{ item.text.substring(0, 300) }}
          </p>

          <div
            v-if="item.primaryPreview"
            class="mt-2 rounded-xl bg-[var(--hover)] px-3 py-2 text-xs text-muted-foreground"
          >
            <span class="font-medium text-foreground/85">{{ item.primaryPreview.title }}: </span>
            <span class="line-clamp-1">{{ item.primaryPreview.text }}</span>
          </div>

          <div v-if="item.rawUserAgent" class="mt-1.5" @click.stop>
            <button
              type="button"
              class="inline-flex items-center gap-1 rounded-full bg-secondary/70 px-2.5 py-0.5 text-[11px] font-medium text-primary transition-colors hover:bg-secondary"
              @click="toggleDeviceDetails(item.id)"
            >
              <component
                :is="expandedDeviceIds.has(item.id) ? ChevronUp : ChevronDown"
                class="size-3"
              />
              <span>{{ t('mail.display.deviceDetails') }}</span>
            </button>
            <pre
              v-if="expandedDeviceIds.has(item.id)"
              class="mt-1.5 whitespace-pre-wrap break-all rounded-xl bg-secondary/70 p-2.5 font-mono text-[11px] text-muted-foreground"
            >{{ item.rawUserAgent }}</pre>
          </div>
        </div>
      </article>
    </TransitionGroup>
    <div ref="sentinel" class="h-1 w-full" />
  </div>
</template>
