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
const statusOptions = [
  { value: 'all', label: '全部状态' },
  { value: 'pending', label: '待审核' },
  { value: 'approved', label: '已通过' },
  { value: 'rejected', label: '已拒绝' },
  { value: 'flagged', label: '已标记' }
];

// 举报原因选项
const reportReasonOptions = [
  { value: 'all', label: '全部原因' },
  { value: 'spam', label: '垃圾信息' },
  { value: 'harassment', label: '骚扰' },
  { value: 'hate', label: '仇恨言论' },
  { value: 'violence', label: '暴力内容' },
  { value: 'adult', label: '成人内容' },
  { value: 'misinformation', label: '虚假信息' },
  { value: 'copyright', label: '侵权' },
  { value: 'other', label: '其他' }
];

// 时间范围选项
const dateRangeOptions = [
  { value: 'all', label: '全部时间' },
  { value: 'today', label: '今天' },
  { value: 'yesterday', label: '昨天' },
  { value: 'week', label: '最近一周' },
  { value: 'month', label: '最近一月' }
];

// 排序选项
const sortOptions = [
  { value: 'newest', label: '最新举报' },
  { value: 'oldest', label: '最早举报' },
  { value: 'most_reports', label: '举报最多' },
  { value: 'most_engagement', label: '互动最多' }
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
          placeholder="搜索推文内容或用户..."
          class="pl-9"
        />
      </div>

      <!-- 状态过滤 -->
      <Select
        :model-value="localFilters.status"
        @update:model-value="updateStatus"
      >
        <SelectTrigger class="w-[140px]">
          <SelectValue placeholder="选择状态" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in statusOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </SelectItem>
        </SelectContent>
      </Select>

      <!-- 举报原因过滤 -->
      <Select
        :model-value="localFilters.reportReason"
        @update:model-value="updateReportReason"
      >
        <SelectTrigger class="w-[140px]">
          <SelectValue placeholder="举报原因" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in reportReasonOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
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
          <SelectValue placeholder="时间范围" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="option in dateRangeOptions"
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
        <SelectTrigger class="w-[140px]">
          <SelectValue placeholder="排序方式" />
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
        @click="resetFilters"
        class="text-muted-foreground"
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
        v-if="localFilters.status !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateStatus('all')"
      >
        状态:
        {{
          statusOptions.find(
            o => o.value === localFilters.status
          )?.label
        }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.reportReason !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateReportReason('all')"
      >
        原因:
        {{
          reportReasonOptions.find(
            o => o.value === localFilters.reportReason
          )?.label
        }}
        <X class="h-3 w-3" />
      </Badge>

      <Badge
        v-if="localFilters.dateRange !== 'all'"
        variant="secondary"
        class="gap-1 cursor-pointer"
        @click="updateDateRange('all')"
      >
        时间:
        {{
          dateRangeOptions.find(
            o => o.value === localFilters.dateRange
          )?.label
        }}
        <X class="h-3 w-3" />
      </Badge>
    </div>
  </div>
</template>
