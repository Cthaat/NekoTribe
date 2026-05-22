<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import { Search, Calendar, X } from 'lucide-vue-next';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';

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

const localFilters = ref({ ...props.modelValue });

watch(
  () => props.modelValue,
  newVal => {
    localFilters.value = { ...newVal };
  },
  { deep: true }
);

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

const hasActiveFilters = computed(
  () =>
    localFilters.value.search !== '' ||
    localFilters.value.status !== 'all' ||
    localFilters.value.reportReason !== 'all' ||
    localFilters.value.dateRange !== 'all'
);

const statusOptions: SelectOption[] = [
  { value: 'all', labelKey: 'moderation.status.all' },
  { value: 'pending', labelKey: 'moderation.status.pending' },
  { value: 'approved', labelKey: 'moderation.status.approved' },
  { value: 'rejected', labelKey: 'moderation.status.rejected' },
  { value: 'flagged', labelKey: 'moderation.status.flagged' },
  { value: 'removed', labelKey: 'moderation.status.removed' },
  { value: 'restored', labelKey: 'moderation.status.restored' }
];

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
  <div class="rounded-xl border border-border/60 bg-card p-3 shadow-none">
    <div class="grid gap-2 sm:flex sm:flex-wrap sm:items-center">
      <div class="relative min-w-0 sm:min-w-[220px] sm:flex-1">
        <Search
          class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          :model-value="localFilters.search"
          :placeholder="t('moderation.filters.searchPlaceholder')"
          class="h-9 pl-8 shadow-xs"
          @update:model-value="updateSearch"
        />
      </div>

      <Select
        :model-value="localFilters.status"
        @update:model-value="updateStatus"
      >
        <SelectTrigger class="h-9 w-full shadow-xs sm:w-[150px]">
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

      <Select
        :model-value="localFilters.reportReason"
        @update:model-value="updateReportReason"
      >
        <SelectTrigger class="h-9 w-full shadow-xs sm:w-[160px]">
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

      <Select
        :model-value="localFilters.dateRange"
        @update:model-value="updateDateRange"
      >
        <SelectTrigger class="h-9 w-full shadow-xs sm:w-[150px]">
          <Calendar class="size-4 text-muted-foreground" />
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

      <Select
        :model-value="localFilters.sortBy"
        @update:model-value="updateSortBy"
      >
        <SelectTrigger class="h-9 w-full shadow-xs sm:w-[170px]">
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

      <Button
        v-if="hasActiveFilters"
        variant="ghost"
        size="sm"
        class="h-9 w-full text-muted-foreground sm:w-auto"
        @click="resetFilters"
      >
        <X class="h-4 w-4" />
        {{ t('common.reset') }}
      </Button>
    </div>

    <div
      v-if="hasActiveFilters"
      class="mt-3 flex flex-wrap items-center gap-1.5 border-t border-border/60 pt-3"
    >
      <span class="text-xs text-muted-foreground">
        {{ t('moderation.filters.current') }}
      </span>

      <button
        v-if="localFilters.search"
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground transition-colors hover:border-border hover:bg-muted hover:text-foreground"
        @click="updateSearch('')"
      >
        {{
          t('moderation.filters.searchBadge', {
            value: localFilters.search
          })
        }}
        <X class="h-3 w-3" />
      </button>

      <button
        v-if="localFilters.status !== 'all'"
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground transition-colors hover:border-border hover:bg-muted hover:text-foreground"
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
      </button>

      <button
        v-if="localFilters.reportReason !== 'all'"
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground transition-colors hover:border-border hover:bg-muted hover:text-foreground"
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
      </button>

      <button
        v-if="localFilters.dateRange !== 'all'"
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground transition-colors hover:border-border hover:bg-muted hover:text-foreground"
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
      </button>
    </div>
  </div>
</template>
