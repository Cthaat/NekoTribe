<script setup lang="ts">
import { ref, watch } from 'vue';
import { v2SearchUsers } from '@/services';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { ScrollArea } from '@/components/ui/scroll-area';
import { User, FileText } from 'lucide-vue-next';

const { t } = useAppLocale();

interface MentionItem {
  type: 'user' | 'tweet';
  id: string;
  userId?: string;
  displayName: string;
  subtitle?: string;
  avatarUrl?: string;
}

const props = defineProps<{
  show: boolean;
  searchQuery: string;
  position?: { top: number; left: number };
}>();

const emit = defineEmits<{
  (e: 'select', item: MentionItem): void;
  (e: 'close'): void;
}>();

const mentionItems = ref<MentionItem[]>([]);
const isLoading = ref(false);
const selectedIndex = ref(0);

async function searchMentions(query: string): Promise<void> {
  if (!query || query.length < 1) {
    mentionItems.value = [];
    return;
  }

  isLoading.value = true;
  try {
    const userResult = await v2SearchUsers({
      q: query,
      page: 1,
      pageSize: 5
    });

    const users: MentionItem[] = userResult.items.map(u => ({
      type: 'user' as const,
      id: u.username,
      userId: String(u.id),
      displayName: u.name,
      subtitle: `@${u.username}`,
      avatarUrl: u.avatarUrl
    }));
    mentionItems.value = [...users];
    selectedIndex.value = 0;
  } catch (error) {
    mentionItems.value = [];
  } finally {
    isLoading.value = false;
  }
}

watch(
  () => props.searchQuery,
  newQuery => {
    searchMentions(newQuery);
  }
);

function selectItem(item: MentionItem): void {
  emit('select', item);
  emit('close');
}

function handleKeyDown(event: KeyboardEvent): void {
  if (!props.show || mentionItems.value.length === 0) return;

  switch (event.key) {
    case 'ArrowDown':
      event.preventDefault();
      selectedIndex.value = Math.min(
        selectedIndex.value + 1,
        mentionItems.value.length - 1
      );
      break;
    case 'ArrowUp':
      event.preventDefault();
      selectedIndex.value = Math.max(selectedIndex.value - 1, 0);
      break;
    case 'Enter': {
      event.preventDefault();
      const selectedItem =
        mentionItems.value[selectedIndex.value];
      if (selectedItem) {
        selectItem(selectedItem);
      }
      break;
    }
    case 'Escape':
      event.preventDefault();
      emit('close');
      break;
  }
}

defineExpose({
  handleKeyDown
});
</script>

<template>
  <div
    v-if="show && mentionItems.length > 0"
    class="fixed z-50 w-[min(20rem,calc(100vw-1rem))] overflow-hidden rounded-xl border border-border/60 bg-popover/95 shadow-lg backdrop-blur"
    :style="{
      top: position?.top ? `${position.top}px` : 'auto',
      left: position?.left ? `${position.left}px` : 'auto'
    }"
  >
    <ScrollArea class="max-h-80 p-1">
      <button
        v-for="(item, index) in mentionItems"
        :key="`${item.type}-${item.id}`"
        type="button"
        class="flex w-full items-center gap-3 rounded-md px-2.5 py-2 text-left transition"
        :class="
          index === selectedIndex
            ? 'bg-accent text-accent-foreground'
            : 'text-foreground hover:bg-accent/60'
        "
        @click="selectItem(item)"
        @mouseenter="selectedIndex = index"
      >
        <Avatar
          v-if="item.type === 'user'"
          class="size-9 ring-1 ring-border"
        >
          <AvatarImage
            :src="item.avatarUrl || ''"
            :alt="item.displayName"
          />
          <AvatarFallback
            class="bg-primary/10 text-xs font-semibold text-primary"
          >
            <User class="h-4 w-4" />
          </AvatarFallback>
        </Avatar>
        <div
          v-else
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
        >
          <FileText class="h-4 w-4 text-muted-foreground" />
        </div>

        <div class="min-w-0 flex-1">
          <div class="truncate text-sm font-medium tracking-tight">
            {{ item.displayName }}
          </div>
          <div
            v-if="item.subtitle"
            class="truncate text-[11px] text-muted-foreground"
          >
            {{ item.subtitle }}
          </div>
        </div>

        <span
          class="shrink-0 rounded-full border border-border/60 bg-muted/40 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-muted-foreground"
        >
          {{
            item.type === 'user'
              ? t('chat.mention.user')
              : t('chat.mention.post')
          }}
        </span>
      </button>

      <div
        v-if="isLoading"
        class="px-3 py-2 text-center text-[11px] text-muted-foreground"
      >
        {{ t('chat.mention.loading') }}
      </div>
    </ScrollArea>
  </div>
</template>
