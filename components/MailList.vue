<script lang="ts" setup>
import type { Mail } from '../data/mails';
import { formatDistanceToNow } from 'date-fns';
import { cn } from '@/lib/utils';
import { Badge } from '@/components/ui/badge';
import { ScrollArea } from '@/components/ui/scroll-area';
import { onMounted, onBeforeUnmount, ref } from 'vue';

interface MailListProps {
  items: Mail[];
  // 可选：当靠近底部时调用的加载更多函数
  loadMore?: () => void;
}

const props = defineProps<MailListProps>();
const selectedMail = defineModel<string>('selectedMail', {
  required: false
});

function getBadgeVariantFromLabel(label: string) {
  if (['work'].includes(label.toLowerCase()))
    return 'default';

  if (['personal'].includes(label.toLowerCase()))
    return 'outline';

  return 'secondary';
}

// 无限滚动：观察列表底部哨兵，接近底部时触发 props.loadMore()
const sentinel = ref<HTMLDivElement | null>(null);
let observer: IntersectionObserver | null = null;
let throttling = false;

function setupObserver() {
  if (!sentinel.value) return;
  // 找到 ScrollArea 的 viewport 作为 root
  const root = sentinel.value.closest(
    '[data-slot="scroll-area-viewport"]'
  ) as Element | null;

  observer = new IntersectionObserver(
    entries => {
      const entry = entries[0];
      if (
        entry.isIntersecting &&
        props.loadMore &&
        !throttling
      ) {
        throttling = true;
        try {
          props.loadMore();
        } finally {
          // 简单节流，避免抖动；父级应配合加载状态更严谨控制
          setTimeout(() => (throttling = false), 800);
        }
      }
    },
    {
      root: root || undefined,
      rootMargin: '0px 0px 200px 0px',
      threshold: 0.01
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
</script>

<template>
  <ScrollArea class="h-screen flex">
    <div class="flex-1 flex flex-col gap-2 p-4 pt-0">
      <TransitionGroup name="list" appear>
        <button
          v-for="item of items"
          :key="item.id"
          :class="
            cn(
              'flex flex-col items-start gap-2 rounded-lg border p-3 text-left text-sm transition-all hover:bg-accent',
              selectedMail === item.id && 'bg-muted'
            )
          "
          @click="selectedMail = String(item.id)"
        >
          <div class="flex w-full flex-col gap-1">
            <div class="flex items-center">
              <div class="flex items-center gap-2">
                <div class="font-semibold">
                  {{ item.name }}
                </div>
                <span
                  v-if="!item.read"
                  class="flex h-2 w-2 rounded-full bg-blue-600"
                />
              </div>
              <div
                :class="
                  cn(
                    'ml-auto text-xs',
                    selectedMail === item.id
                      ? 'text-foreground'
                      : 'text-muted-foreground'
                  )
                "
              >
                {{
                  formatDistanceToNow(new Date(item.date), {
                    addSuffix: true
                  })
                }}
              </div>
            </div>

            <div class="text-xs font-medium">
              {{ item.subject }}
            </div>
          </div>
          <div
            class="line-clamp-2 text-xs text-muted-foreground"
          >
            {{ item.text.substring(0, 300) }}
          </div>
          <div class="flex items-center gap-2">
            <Badge
              v-for="label of item.labels"
              :key="label"
              :variant="getBadgeVariantFromLabel(label)"
            >
              {{ label }}
            </Badge>
          </div>
        </button>
      </TransitionGroup>
      <!-- 无限滚动哨兵：接近底部时触发 loadMore -->
      <div ref="sentinel" class="h-1 w-full"></div>
    </div>
  </ScrollArea>
</template>

<style scoped>
.list-move,
.list-enter-active,
.list-leave-active {
  transition: all 0.5s ease;
}

.list-enter-from,
.list-leave-to {
  opacity: 0;
  transform: translateY(15px);
}

.list-leave-active {
  position: absolute;
}
</style>
