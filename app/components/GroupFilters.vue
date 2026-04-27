<script setup lang="ts">
import { ref, watch } from 'vue';
import {
  Search,
  X,
  SlidersHorizontal
} from 'lucide-vue-next';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import type { GroupFiltersData } from '@/types/groups';

export type { GroupFiltersData } from '@/types/groups';

const props = withDefaults(
  defineProps<{
    modelValue: GroupFiltersData;
  }>(),
  {
    modelValue: () => ({
      search: '',
      privacy: 'all',
      category: 'all',
      sortBy: 'popular'
    })
  }
);

const emit = defineEmits<{
  (e: 'update:modelValue', value: GroupFiltersData): void;
  (e: 'reset'): void;
}>();

// 本地状态
const localFilters = ref({ ...props.modelValue });

// 监听 props 变化
watch(
  () => props.modelValue,
  newVal => {
    localFilters.value = { ...newVal };
  },
  { deep: true }
);

// 更新方法
const updateSearch = (value: string | number) => {
  localFilters.value.search = String(value);
  emit('update:modelValue', { ...localFilters.value });
};

const updatePrivacy = (value: unknown) => {
  localFilters.value.privacy = value
    ? String(value)
    : 'all';
  emit('update:modelValue', { ...localFilters.value });
};

const updateCategory = (value: unknown) => {
  localFilters.value.category = value
    ? String(value)
    : 'all';
  emit('update:modelValue', { ...localFilters.value });
};

const updateSortBy = (value: unknown) => {
  localFilters.value.sortBy = value
    ? String(value)
    : 'popular';
  emit('update:modelValue', { ...localFilters.value });
};

// 重置过滤器
const resetFilters = () => {
  localFilters.value = {
    search: '',
    privacy: 'all',
    category: 'all',
    sortBy: 'popular'
  };
  emit('update:modelValue', { ...localFilters.value });
  emit('reset');
};

// 检查是否有活动过滤器
const hasActiveFilters = () => {
  return (
    localFilters.value.search !== '' ||
    localFilters.value.privacy !== 'all' ||
    localFilters.value.category !== 'all'
  );
};

// 隐私选项
const privacyOptions = [
  { value: 'all', label: '全部类型' },
  { value: 'public', label: '公开群组' },
  { value: 'private', label: '私密群组' },
  { value: 'secret', label: '隐秘群组' }
];

// 分类选项
const categoryOptions = [
  { value: 'all', label: '全部分类' },
  { value: 'tech', label: '科技' },
  { value: 'game', label: '游戏' },
  { value: 'music', label: '音乐' },
  { value: 'art', label: '艺术' },
  { value: 'life', label: '生活' },
  { value: 'study', label: '学习' },
  { value: 'work', label: '工作' },
  { value: 'other', label: '其他' }
];

// 排序选项
const sortOptions = [
  { value: 'popular', label: '最热门' },
  { value: 'newest', label: '最新创建' },
  { value: 'active', label: '最活跃' },
  { value: 'members', label: '成员最多' }
];
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- 搜索和主要过滤器 -->
    <div class="flex flex-wrap items-center gap-3">
      <!-- 搜索框 -->
      <div class="relative flex-1 min-w-[200px] max-w-md">
        <Search
          class="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground"
        />
        <Input
          :model-value="localFilters.search"
          @update:model-value="updateSearch"
          placeholder="搜索群组名称或描述..."
          class="pl-9"
        />
      </div>

      <!-- 隐私类型 -->
      <Select
        :model-value="localFilters.privacy"
        @update:model-value="updatePrivacy"
      >
        <SelectTrigger class="w-[130px]">
          <SelectValue placeholder="群组类型" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in privacyOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </SelectItem>
        </SelectContent>
      </Select>

      <!-- 分类 -->
      <Select
        :model-value="localFilters.category"
        @update:model-value="updateCategory"
      >
        <SelectTrigger class="w-[120px]">
          <SelectValue placeholder="分类" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in categoryOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </SelectItem>
        </SelectContent>
      </Select>

      <!-- 排序 -->
      <Select
        :model-value="localFilters.sortBy"
        @update:model-value="updateSortBy"
      >
        <SelectTrigger class="w-[120px]">
          <SlidersHorizontal class="h-4 w-4 mr-2" />
          <SelectValue placeholder="排序" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in sortOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </SelectItem>
        </SelectContent>
      </Select>

      <!-- 重置按钮 -->
      <Button
        v-if="hasActiveFilters()"
        variant="ghost"
        size="sm"
        class="text-muted-foreground"
        @click="resetFilters"
      >
        <X class="h-4 w-4 mr-1" />
        重置
      </Button>
    </div>

    <!-- 活动过滤器标签 -->
    <div
      v-if="hasActiveFilters()"
      class="flex flex-wrap items-center gap-2"
    >
      <span class="text-sm text-muted-foreground"
        >当前过滤：</span
      >

      <Badge
        v-if="localFilters.search"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateSearch('')"
      >
        搜索: {{ localFilters.search }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.privacy !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updatePrivacy('all')"
      >
        类型:
        {{
          privacyOptions.find(
            o => o.value === localFilters.privacy
          )?.label
        }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.category !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateCategory('all')"
      >
        分类:
        {{
          categoryOptions.find(
            o => o.value === localFilters.category
          )?.label
        }}
        <X class="h-3 w-3" />
      </Badge>
    </div>
  </div>
</template>
