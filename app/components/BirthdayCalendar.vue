<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import {
  CalendarDate,
  type DateValue,
  getLocalTimeZone,
  today
} from '@internationalized/date';
import {
  Calendar,
  CalendarCell,
  CalendarCellTrigger,
  CalendarGrid,
  CalendarGridBody,
  CalendarGridHead,
  CalendarGridRow,
  CalendarHeadCell
} from '@/components/ui/calendar';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { CalendarRoot } from 'reka-ui';

const props = defineProps<{
  modelValue?: DateValue;
  minYear?: number;
  maxYear?: number;
}>();

const emit = defineEmits<{
  (e: 'update:modelValue', value: DateValue | undefined): void;
}>();

const { t, locale } = useAppLocale();

const todayDate = today(getLocalTimeZone());
const maxYear = computed(() => props.maxYear ?? todayDate.year);
const minYear = computed(() => props.minYear ?? todayDate.year - 100);

const placeholder = ref<DateValue>(
  props.modelValue ?? new CalendarDate(todayDate.year - 18, 1, 1)
);

watch(
  () => props.modelValue,
  value => {
    if (value) placeholder.value = value;
  }
);

const years = computed(() => {
  const result: number[] = [];
  for (let y = maxYear.value; y >= minYear.value; y--) result.push(y);
  return result;
});

const monthFormatter = computed(
  () =>
    new Intl.DateTimeFormat(
      locale.value === 'zh' ? 'zh-CN' : 'en-US',
      { month: 'long' }
    )
);

const months = computed(() =>
  Array.from({ length: 12 }, (_, i) => ({
    value: i + 1,
    label: monthFormatter.value.format(new Date(2000, i, 1))
  }))
);

function onYearChange(value: string | number): void {
  const year = Number(value);
  if (!Number.isFinite(year)) return;
  placeholder.value = placeholder.value.set({ year });
}

function onMonthChange(value: string | number): void {
  const month = Number(value);
  if (!Number.isFinite(month)) return;
  placeholder.value = placeholder.value.set({ month, day: 1 });
}
</script>

<template>
  <CalendarRoot
    v-slot="{ grid, weekDays }"
    :model-value="props.modelValue"
    :placeholder="placeholder"
    class="p-3"
    @update:model-value="emit('update:modelValue', $event as DateValue | undefined)"
    @update:placeholder="placeholder = $event"
  >
    <div class="flex items-center justify-center gap-2 pt-1">
      <Select
        :model-value="String(placeholder.month)"
        @update:model-value="onMonthChange"
      >
        <SelectTrigger class="h-8 w-[110px]">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem
            v-for="m in months"
            :key="m.value"
            :value="String(m.value)"
          >
            {{ m.label }}
          </SelectItem>
        </SelectContent>
      </Select>
      <Select
        :model-value="String(placeholder.year)"
        @update:model-value="onYearChange"
      >
        <SelectTrigger class="h-8 w-[90px]">
          <SelectValue />
        </SelectTrigger>
        <SelectContent class="max-h-64">
          <SelectItem
            v-for="y in years"
            :key="y"
            :value="String(y)"
          >
            {{ y }}
          </SelectItem>
        </SelectContent>
      </Select>
    </div>

    <div
      class="flex flex-col gap-y-4 mt-4 sm:flex-row sm:gap-x-4 sm:gap-y-0"
    >
      <CalendarGrid
        v-for="month in grid"
        :key="month.value.toString()"
      >
        <CalendarGridHead>
          <CalendarGridRow>
            <CalendarHeadCell v-for="day in weekDays" :key="day">
              {{ day }}
            </CalendarHeadCell>
          </CalendarGridRow>
        </CalendarGridHead>
        <CalendarGridBody>
          <CalendarGridRow
            v-for="(weekDates, index) in month.rows"
            :key="`weekDate-${index}`"
            class="mt-2 w-full"
          >
            <CalendarCell
              v-for="weekDate in weekDates"
              :key="weekDate.toString()"
              :date="weekDate"
            >
              <CalendarCellTrigger
                :day="weekDate"
                :month="month.value"
              />
            </CalendarCell>
          </CalendarGridRow>
        </CalendarGridBody>
      </CalendarGrid>
    </div>
  </CalendarRoot>
</template>
