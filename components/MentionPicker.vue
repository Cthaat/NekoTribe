<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import { apiFetch } from '@/composables/useApi';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { User, FileText } from 'lucide-vue-next';

interface MentionItem {
  type: 'user' | 'tweet';
  id: string;
  userId?: string; // 用户ID，用于跳转
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

// 搜索用户和推文
async function searchMentions(query: string) {
  if (!query || query.length < 1) {
    mentionItems.value = [];
    return;
  }

  isLoading.value = true;
  try {
    // 搜索用户
    const userRes = await apiFetch<any>(
      '/api/v1/users/search',
      {
        query: { q: query, pageSize: 5 }
      }
    );

    const users: MentionItem[] = (
      userRes?.data?.users || []
    ).map((u: any) => ({
      type: 'user' as const,
      id: u.username,
      userId: u.userId,
      displayName: u.displayName || u.username,
      subtitle: `@${u.username}`,
      avatarUrl: u.avatarUrl
    }));

    // TODO: 搜索推文（如果需要）
    // const tweetRes = await apiFetch<any>('/api/v1/tweets/search', {
    //   method: 'POST',
    //   body: { query, limit: 3 }
    // });

    mentionItems.value = [...users];
    selectedIndex.value = 0;
  } catch (error) {
    console.error('搜索提及失败:', error);
    mentionItems.value = [];
  } finally {
    isLoading.value = false;
  }
}

// 监听搜索查询变化
watch(
  () => props.searchQuery,
  newQuery => {
    searchMentions(newQuery);
  }
);

// 选择项目
function selectItem(item: MentionItem) {
  emit('select', item);
  emit('close');
}

// 键盘导航
function handleKeyDown(event: KeyboardEvent) {
  if (!props.show || mentionItems.value.length === 0)
    return;

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
      selectedIndex.value = Math.max(
        selectedIndex.value - 1,
        0
      );
      break;
    case 'Enter':
      event.preventDefault();
      if (mentionItems.value[selectedIndex.value]) {
        selectItem(mentionItems.value[selectedIndex.value]);
      }
      break;
    case 'Escape':
      event.preventDefault();
      emit('close');
      break;
  }
}

// 暴露键盘处理方法
defineExpose({
  handleKeyDown
});
</script>

<template>
  <div
    v-if="show && mentionItems.length > 0"
    class="fixed z-50 w-80 rounded-lg border border-gray-700 bg-gray-900 shadow-lg"
    :style="{
      top: position?.top ? `${position.top}px` : 'auto',
      left: position?.left ? `${position.left}px` : 'auto'
    }"
  >
    <div class="max-h-80 overflow-y-auto">
      <div
        v-for="(item, index) in mentionItems"
        :key="`${item.type}-${item.id}`"
        class="flex items-center gap-3 px-4 py-3 cursor-pointer transition-colors"
        :class="{
          'bg-gray-800': index === selectedIndex,
          'hover:bg-gray-800': index !== selectedIndex
        }"
        @click="selectItem(item)"
        @mouseenter="selectedIndex = index"
      >
        <!-- 头像或图标 -->
        <Avatar
          v-if="item.type === 'user'"
          class="h-10 w-10"
        >
          <AvatarImage
            :src="item.avatarUrl || ''"
            :alt="item.displayName"
          />
          <AvatarFallback>
            <User class="h-5 w-5" />
          </AvatarFallback>
        </Avatar>
        <div
          v-else
          class="flex h-10 w-10 items-center justify-center rounded-full bg-gray-800"
        >
          <FileText class="h-5 w-5 text-gray-400" />
        </div>

        <!-- 信息 -->
        <div class="flex-1 min-w-0">
          <div class="font-medium text-white truncate">
            {{ item.displayName }}
          </div>
          <div
            v-if="item.subtitle"
            class="text-sm text-gray-400 truncate"
          >
            {{ item.subtitle }}
          </div>
        </div>

        <!-- 类型标识 -->
        <div class="text-xs text-gray-500 uppercase">
          {{ item.type === 'user' ? '用户' : '推文' }}
        </div>
      </div>

      <div
        v-if="isLoading"
        class="px-4 py-3 text-center text-gray-400"
      >
        搜索中...
      </div>
    </div>
  </div>
</template>
