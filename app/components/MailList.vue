<script lang="ts" setup>
import { formatDistanceToNow } from 'date-fns';
import { cn } from '@/lib/utils';
import { ScrollArea } from '@/components/ui/scroll-area';
import {
  onMounted,
  onBeforeUnmount,
  ref,
  watch,
  nextTick
} from 'vue';
import type { MailItem } from './mail/types';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';

interface MailListProps {
  items: MailItem[];
  loadMore?: () => void;
}

const emit = defineEmits(['read-mail']);

const props = defineProps<MailListProps>();
const selectedMail = defineModel<string>('selectedMail', {
  required: false
});

const localItems = ref<MailItem[]>([]);
watch(
  () => props.items,
  items => {
    localItems.value = (items ?? []).map(it => ({ ...it }));
    nextTick(() => {
      if (observer && sentinel.value) {
        try {
          observer.unobserve(sentinel.value);
        } catch {
          // The sentinel may already be detached during fast list swaps.
        }
        observer.observe(sentinel.value);
      }
    });
  },
  { immediate: true }
);

function getLabelClass(label: string) {
  const value = label.toLowerCase();
  if (value === 'work') {
    return 'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300';
  }
  if (value === 'personal') {
    return 'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300';
  }
  return 'border-border/60 bg-muted/40 text-muted-foreground';
}

const sentinel = ref<HTMLDivElement | null>(null);
let observer: IntersectionObserver | null = null;
let throttling = false;

function reobserveSentinel() {
  if (!observer || !sentinel.value) return;
  try {
    observer.unobserve(sentinel.value);
  } catch {
    // The sentinel can be removed before IntersectionObserver catches up.
  }
  observer.observe(sentinel.value);
}

function setupObserver() {
  if (!sentinel.value) return;
  const root = sentinel.value.closest(
    '[data-slot="scroll-area-viewport"]'
  ) as Element | null;

  observer = new IntersectionObserver(
    entries => {
      const entry = entries[0];
      if (!entry) return;
      if (
        entry.isIntersecting &&
        props.loadMore &&
        !throttling
      ) {
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
    {
      root: root || undefined,
      rootMargin: '0px 0px 200px 0px',
      threshold: 0
    }
  );
  observer.observe(sentinel.value);
}

onMounted(() => setupObserver());
onBeforeUnmount(() => {
  if (observer && sentinel.value)
    observer.unobserve(sentinel.value);
  observer?.disconnect();
  observer = null;
});

function selectMail(mailId: string) {
  selectedMail.value = mailId;
  const target = localItems.value.find(
    m => String(m.id) === String(mailId)
  );
  if (target) target.read = true;

  emit('read-mail', mailId);
}
</script>

<template>
  <ScrollArea class="h-[min(32rem,calc(100dvh-12rem))] md:h-full">
    <div class="flex flex-col gap-1 p-2">
      <TransitionGroup name="list" appear>
        <button
          v-for="item of localItems"
          :key="item.id"
          type="button"
          :class="
            cn(
              'group/mail relative flex w-full items-start gap-3 rounded-lg border border-transparent p-3 text-left text-sm transition-colors',
              selectedMail === item.id
                ? 'border-border/60 bg-accent text-accent-foreground'
                : 'hover:border-border/60 hover:bg-accent/50'
            )
          "
          @click="selectMail(String(item.id))"
        >
          <span
            v-if="selectedMail === item.id"
            class="absolute inset-y-2 left-0 w-0.5 rounded-full bg-primary"
            aria-hidden="true"
          />
          <Avatar class="mt-0.5 size-9 shrink-0 ring-1 ring-border">
            <AvatarImage
              :src="item.avatar"
              :alt="item.name"
            />
            <AvatarFallback class="text-xs">
              {{
                (item.name || item.typeLabel)
                  .substring(0, 2)
                  .toUpperCase()
              }}
            </AvatarFallback>
          </Avatar>

          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span
                v-if="!item.read"
                class="h-1.5 w-1.5 shrink-0 rounded-full bg-primary"
                aria-hidden="true"
              />
              <span
                class="min-w-0 truncate text-sm"
                :class="!item.read ? 'font-semibold text-foreground' : 'font-medium'"
              >
                {{ item.name }}
              </span>
              <span
                class="ml-auto shrink-0 text-[11px] tabular-nums"
                :class="
                  selectedMail === item.id
                    ? 'text-foreground/80'
                    : 'text-muted-foreground'
                "
              >
                {{
                  formatDistanceToNow(new Date(item.date), {
                    addSuffix: true
                  })
                }}
              </span>
            </div>

            <div
              class="mt-0.5 line-clamp-1 text-xs"
              :class="!item.read ? 'font-medium text-foreground' : 'text-muted-foreground'"
            >
              {{ item.subject }}
            </div>

            <div
              class="mt-1.5 line-clamp-2 text-xs text-muted-foreground"
            >
              {{ item.text.substring(0, 300) }}
            </div>

            <div
              v-if="item.primaryPreview"
              class="mt-2.5 rounded-md border border-border/60 bg-muted/30 px-2.5 py-2"
            >
              <div class="text-xs font-medium text-foreground">
                {{ item.primaryPreview.title }}
              </div>
              <p
                class="mt-0.5 line-clamp-2 text-xs text-muted-foreground"
              >
                {{ item.primaryPreview.text }}
              </p>
            </div>

            <div
              v-if="item.labels?.length || item.priority !== 'normal'"
              class="mt-2 flex flex-wrap items-center gap-1"
            >
              <span
                v-for="label of item.labels"
                :key="label"
                :class="
                  cn(
                    'inline-flex items-center rounded-full border px-1.5 py-0 text-[10px] font-medium',
                    getLabelClass(label)
                  )
                "
              >
                {{ label }}
              </span>
              <span
                v-if="item.priority !== 'normal'"
                class="inline-flex items-center rounded-full border border-border/60 bg-muted/40 px-1.5 py-0 text-[10px] font-medium text-muted-foreground"
              >
                {{ item.priorityLabel }}
              </span>
            </div>
          </div>
        </button>
      </TransitionGroup>
      <div ref="sentinel" class="h-1 w-full" />
    </div>
  </ScrollArea>
</template>

<style scoped>
.list-move,
.list-enter-active,
.list-leave-active {
  transition: all 0.3s ease;
}

.list-enter-from,
.list-leave-to {
  opacity: 0;
  transform: translateY(8px);
}

.list-leave-active {
  position: absolute;
}
</style>
