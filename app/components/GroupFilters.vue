<script setup lang="ts">
import { ref, watch } from 'vue';
import {
  Search,
  X,
  SlidersHorizontal
} from 'lucide-vue-next';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
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
  <div class="flex flex-col gap-3">
    <div class="grid gap-2 sm:flex sm:flex-wrap sm:items-center">
      <div class="relative min-w-0 sm:min-w-[220px] sm:max-w-md sm:flex-1">
        <Search
          class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          :model-value="localFilters.search"
          :placeholder="t('groups.filters.searchPlaceholder')"
          class="h-9 pl-9 shadow-xs focus-visible:ring-2 focus-visible:ring-ring/40"
          @update:model-value="updateSearch"
        />
      </div>

      <Select
        :model-value="localFilters.privacy"
        @update:model-value="updatePrivacy"
      >
        <SelectTrigger class="h-9 w-full sm:w-[140px]">
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

      <Select
        :model-value="localFilters.category"
        @update:model-value="updateCategory"
      >
        <SelectTrigger class="h-9 w-full sm:w-[130px]">
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

      <Select
        :model-value="localFilters.sortBy"
        @update:model-value="updateSortBy"
      >
        <SelectTrigger class="h-9 w-full sm:w-[140px]">
          <SlidersHorizontal class="h-3.5 w-3.5" />
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

      <Button
        v-if="hasActiveFilters()"
        variant="ghost"
        size="sm"
        class="h-9 w-full text-muted-foreground sm:w-auto"
        @click="resetFilters"
      >
        <X class="h-3.5 w-3.5" />
        {{ t('common.reset') }}
      </Button>
    </div>

    <div
      v-if="hasActiveFilters()"
      class="flex flex-wrap items-center gap-1.5"
    >
      <span class="text-xs text-muted-foreground">
        {{ t('groups.filters.current') }}
      </span>

      <button
        v-if="localFilters.search"
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-sky-200/60 bg-sky-100/60 px-2 py-0.5 text-[11px] font-medium text-sky-700 transition hover:bg-sky-200/60 hover:text-sky-800 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300 dark:hover:bg-sky-900/40"
        @click="updateSearch('')"
      >
        {{ t('groups.filters.searchBadge', { value: localFilters.search }) }}
        <X class="h-3 w-3" />
      </button>

      <button
        v-if="localFilters.privacy !== 'all'"
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-emerald-200/60 bg-emerald-100/60 px-2 py-0.5 text-[11px] font-medium text-emerald-700 transition hover:bg-emerald-200/60 hover:text-emerald-800 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300 dark:hover:bg-emerald-900/40"
        @click="updatePrivacy('all')"
      >
        {{ t('groups.filters.typeBadge') }}
        {{ getPrivacyOptionLabel(localFilters.privacy) }}
        <X class="h-3 w-3" />
      </button>

      <button
        v-if="localFilters.category !== 'all'"
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-violet-200/60 bg-violet-100/60 px-2 py-0.5 text-[11px] font-medium text-violet-700 transition hover:bg-violet-200/60 hover:text-violet-800 dark:border-violet-900/40 dark:bg-violet-950/40 dark:text-violet-300 dark:hover:bg-violet-900/40"
        @click="updateCategory('all')"
      >
        {{ t('groups.filters.categoryBadge') }}
        {{ getCategoryOptionLabel(localFilters.category) }}
        <X class="h-3 w-3" />
      </button>
    </div>
  </div>
</template>
