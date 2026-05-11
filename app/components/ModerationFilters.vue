<script setup lang="ts">
import { ref, watch } from 'vue';
import {
  Search,
  Filter,
  Calendar,
  X
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
import {
  Popover,
  PopoverContent,
  PopoverTrigger
} from '@/components/ui/popover';

interface SelectOption {
  value: string;
  labelKey: string;
}

export interface ModerationFiltersData {
  search: string;
  status: string;
  reportReason: string;
  dateRange: string;
  sortBy: string;
}

const props = withDefaults(
  defineProps<{
    modelValue: ModerationFiltersData;
  }>(),
  {
    modelValue: () => ({
      search: '',
      status: 'all',
      reportReason: 'all',
      dateRange: 'all',
      sortBy: 'newest'
    })
  }
);

const emit = defineEmits<{
  (
    e: 'update:modelValue',
    value: ModerationFiltersData
  ): void;
  (e: 'reset'): void;
}>();

const { t } = useAppLocale();

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

// 更新过滤器 - 为不同字段提供独立的更新方法
const updateSearch = (value: string | number) => {
  localFilters.value.search = String(value);
  emit('update:modelValue', { ...localFilters.value });
};

const updateStatus = (value: unknown) => {
  localFilters.value.status = value ? String(value) : 'all';
  emit('update:modelValue', { ...localFilters.value });
};

const updateReportReason = (value: unknown) => {
  localFilters.value.reportReason = value
    ? String(value)
    : 'all';
  emit('update:modelValue', { ...localFilters.value });
};

const updateDateRange = (value: unknown) => {
  localFilters.value.dateRange = value
    ? String(value)
    : 'all';
  emit('update:modelValue', { ...localFilters.value });
};

const updateSortBy = (value: unknown) => {
  localFilters.value.sortBy = value
    ? String(value)
    : 'newest';
  emit('update:modelValue', { ...localFilters.value });
};

// 重置过滤器
const resetFilters = () => {
  localFilters.value = {
    search: '',
    status: 'all',
    reportReason: 'all',
    dateRange: 'all',
    sortBy: 'newest'
  };
  emit('update:modelValue', { ...localFilters.value });
  emit('reset');
};

// 检查是否有活动过滤器
const hasActiveFilters = () => {
  return (
    localFilters.value.search !== '' ||
    localFilters.value.status !== 'all' ||
    localFilters.value.reportReason !== 'all' ||
    localFilters.value.dateRange !== 'all'
  );
};

// 状态选项
const statusOptions: SelectOption[] = [
  { value: 'all', labelKey: 'moderation.status.all' },
  { value: 'pending', labelKey: 'moderation.status.pending' },
  { value: 'approved', labelKey: 'moderation.status.approved' },
  { value: 'rejected', labelKey: 'moderation.status.rejected' },
  { value: 'flagged', labelKey: 'moderation.status.flagged' },
  { value: 'removed', labelKey: 'moderation.status.removed' },
  { value: 'restored', labelKey: 'moderation.status.restored' }
];

// 举报原因选项
const reportReasonOptions: SelectOption[] = [
  { value: 'all', labelKey: 'moderation.filters.reasons.all' },
  { value: 'spam', labelKey: 'moderation.filters.reasons.spam' },
  {
    value: 'harassment',
    labelKey: 'moderation.filters.reasons.harassment'
  },
  { value: 'hate', labelKey: 'moderation.filters.reasons.hate' },
  {
    value: 'violence',
    labelKey: 'moderation.filters.reasons.violence'
  },
  { value: 'adult', labelKey: 'moderation.filters.reasons.adult' },
  {
    value: 'misinformation',
    labelKey: 'moderation.filters.reasons.misinformation'
  },
  {
    value: 'copyright',
    labelKey: 'moderation.filters.reasons.copyright'
  },
  { value: 'other', labelKey: 'moderation.filters.reasons.other' }
];

// 时间范围选项
const dateRangeOptions: SelectOption[] = [
  { value: 'all', labelKey: 'moderation.filters.dateRanges.all' },
  {
    value: 'today',
    labelKey: 'moderation.filters.dateRanges.today'
  },
  {
    value: 'yesterday',
    labelKey: 'moderation.filters.dateRanges.yesterday'
  },
  { value: 'week', labelKey: 'moderation.filters.dateRanges.week' },
  {
    value: 'month',
    labelKey: 'moderation.filters.dateRanges.month'
  }
];

// 排序选项
const sortOptions: SelectOption[] = [
  { value: 'newest', labelKey: 'moderation.filters.sort.newest' },
  { value: 'oldest', labelKey: 'moderation.filters.sort.oldest' },
  {
    value: 'most_reports',
    labelKey: 'moderation.filters.sort.mostReports'
  },
  {
    value: 'most_engagement',
    labelKey: 'moderation.filters.sort.mostEngagement'
  }
];

const getOptionLabel = (
  options: SelectOption[],
  value: string
): string => {
  const option = options.find(item => item.value === value);
  return option ? t(option.labelKey) : value;
};
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
          :placeholder="t('moderation.filters.searchPlaceholder')"
          class="pl-9"
        />
      </div>

      <!-- 状态过滤 -->
      <Select
        :model-value="localFilters.status"
        @update:model-value="updateStatus"
      >
        <SelectTrigger class="w-[140px]">
          <SelectValue
            :placeholder="
              t('moderation.filters.statusPlaceholder')
            "
          />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in statusOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ t(option.labelKey) }}
          </SelectItem>
        </SelectContent>
      </Select>

      <!-- 举报原因过滤 -->
      <Select
        :model-value="localFilters.reportReason"
        @update:model-value="updateReportReason"
      >
        <SelectTrigger class="w-[140px]">
          <SelectValue
            :placeholder="
              t('moderation.filters.reportReasonPlaceholder')
            "
          />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in reportReasonOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ t(option.labelKey) }}
          </SelectItem>
        </SelectContent>
      </Select>

      <!-- 时间范围 -->
      <Select
        :model-value="localFilters.dateRange"
        @update:model-value="updateDateRange"
      >
        <SelectTrigger class="w-[140px]">
          <Calendar class="h-4 w-4 mr-2" />
          <SelectValue
            :placeholder="
              t('moderation.filters.dateRangePlaceholder')
            "
          />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in dateRangeOptions"
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
        <SelectTrigger class="w-[140px]">
          <SelectValue
            :placeholder="t('moderation.filters.sortPlaceholder')"
          />
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
        @click="resetFilters"
        class="text-muted-foreground"
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
        >{{ t('moderation.filters.current') }}</span
      >

      <Badge
        v-if="localFilters.search"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateSearch('')"
      >
        {{
          t('moderation.filters.searchBadge', {
            value: localFilters.search
          })
        }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.status !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateStatus('all')"
      >
        {{
          t('moderation.filters.statusBadge', {
            value: getOptionLabel(
              statusOptions,
              localFilters.status
            )
          })
        }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.reportReason !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateReportReason('all')"
      >
        {{
          t('moderation.filters.reasonBadge', {
            value: getOptionLabel(
              reportReasonOptions,
              localFilters.reportReason
            )
          })
        }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.dateRange !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateDateRange('all')"
      >
        {{
          t('moderation.filters.dateBadge', {
            value: getOptionLabel(
              dateRangeOptions,
              localFilters.dateRange
            )
          })
        }}
        <X class="h-3 w-3" />
      </Badge>
    </div>
  </div>
</template>
