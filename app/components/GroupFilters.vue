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
const { t } = useAppLocale();

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
  { value: 'all', labelKey: 'groups.filters.privacy.all' },
  { value: 'public', labelKey: 'groups.filters.privacy.public' },
  { value: 'private', labelKey: 'groups.filters.privacy.private' },
  { value: 'secret', labelKey: 'groups.filters.privacy.secret' }
];

// 分类选项
const categoryOptions = [
  { value: 'all', labelKey: 'groups.filters.category.all' },
  { value: 'tech', labelKey: 'groups.filters.category.tech' },
  { value: 'game', labelKey: 'groups.filters.category.game' },
  { value: 'music', labelKey: 'groups.filters.category.music' },
  { value: 'art', labelKey: 'groups.filters.category.art' },
  { value: 'life', labelKey: 'groups.filters.category.life' },
  { value: 'study', labelKey: 'groups.filters.category.study' },
  { value: 'work', labelKey: 'groups.filters.category.work' },
  { value: 'other', labelKey: 'groups.filters.category.other' }
];

// 排序选项
const sortOptions = [
  { value: 'popular', labelKey: 'groups.filters.sort.popular' },
  { value: 'newest', labelKey: 'groups.filters.sort.newest' },
  { value: 'active', labelKey: 'groups.filters.sort.active' },
  { value: 'members', labelKey: 'groups.filters.sort.members' }
];

function getPrivacyOptionLabel(value: string): string {
  return t(
    privacyOptions.find(option => option.value === value)
      ?.labelKey || 'groups.filters.privacy.all'
  );
}

function getCategoryOptionLabel(value: string): string {
  return t(
    categoryOptions.find(option => option.value === value)
      ?.labelKey || 'groups.filters.category.all'
  );
}
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
          :placeholder="t('groups.filters.searchPlaceholder')"
          class="pl-9"
        />
      </div>

      <!-- 隐私类型 -->
      <Select
        :model-value="localFilters.privacy"
        @update:model-value="updatePrivacy"
      >
        <SelectTrigger class="w-[130px]">
          <SelectValue :placeholder="t('groups.filters.privacyPlaceholder')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in privacyOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ t(option.labelKey) }}
          </SelectItem>
        </SelectContent>
      </Select>

      <!-- 分类 -->
      <Select
        :model-value="localFilters.category"
        @update:model-value="updateCategory"
      >
        <SelectTrigger class="w-[120px]">
          <SelectValue :placeholder="t('groups.filters.categoryPlaceholder')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in categoryOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ t(option.labelKey) }}
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
          <SelectValue :placeholder="t('groups.filters.sortPlaceholder')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in sortOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ t(option.labelKey) }}
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
        {{ t('common.reset') }}
      </Button>
    </div>

    <!-- 活动过滤器标签 -->
    <div
      v-if="hasActiveFilters()"
      class="flex flex-wrap items-center gap-2"
    >
      <span class="text-sm text-muted-foreground"
        >{{ t('groups.filters.current') }}</span
      >

      <Badge
        v-if="localFilters.search"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateSearch('')"
      >
        {{ t('groups.filters.searchBadge', { value: localFilters.search }) }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.privacy !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updatePrivacy('all')"
      >
        {{ t('groups.filters.typeBadge') }}
        {{ getPrivacyOptionLabel(localFilters.privacy) }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.category !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateCategory('all')"
      >
        {{ t('groups.filters.categoryBadge') }}
        {{ getCategoryOptionLabel(localFilters.category) }}
        <X class="h-3 w-3" />
      </Badge>
    </div>
  </div>
</template>
