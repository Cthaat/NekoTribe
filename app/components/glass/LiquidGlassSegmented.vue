<script setup lang="ts">
import { computed } from 'vue';

export interface LiquidGlassSegmentOption {
  value: string;
  label: string;
  disabled?: boolean;
}

const props = withDefaults(
  defineProps<{
    items: readonly LiquidGlassSegmentOption[];
    modelValue: string;
    ariaLabel?: string;
    tone?: 'primary' | 'tonal';
  }>(),
  {
    ariaLabel: undefined,
    tone: 'primary'
  }
);

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
}>();

const activeIndex = computed(() => {
  const index = props.items.findIndex(item => item.value === props.modelValue);
  return index >= 0 ? index : 0;
});

function selectItem(item: LiquidGlassSegmentOption): void {
  if (item.disabled || item.value === props.modelValue) return;
  emit('update:modelValue', item.value);
}
const { events, pressed, pillStyle, itemStyle } = useLiquidScrub(activeIndex, index => {
  const item = props.items[index];
  if (item) selectItem(item);
});
const tabStop = computed(() => props.items.findIndex(item => item.value === props.modelValue && !item.disabled));
function onKeydown(event: KeyboardEvent, index: number) {
  const buttons = Array.from((event.currentTarget as HTMLElement).parentElement!
    .querySelectorAll<HTMLButtonElement>('button:enabled'));
  const offset = buttons.indexOf(event.currentTarget as HTMLButtonElement);
  const next = { Home: 0, End: buttons.length - 1, ArrowLeft: (offset - 1 + buttons.length) % buttons.length,
    ArrowRight: (offset + 1) % buttons.length }[event.key];
  if (next === undefined || props.items[index]?.disabled) return;
  event.preventDefault();
  buttons[next]?.focus();
  buttons[next]?.click();
}
</script>

<template>
  <div
    role="tablist"
    :aria-label="ariaLabel"
    v-on="events"
    :data-pressed="pressed"
    class="liquid-scrub relative grid flex-1 rounded-full bg-secondary p-1"
    :style="{ gridTemplateColumns: `repeat(${Math.max(1, items.length)}, minmax(0, 1fr))` }"
  >
    <span
      v-if="items.length > 0"
      aria-hidden="true"
      class="pointer-events-none absolute top-1 bottom-1 left-1 rounded-full liquid-glass-active-pill scrub-pill"
      :class="
        tone === 'primary'
          ? 'bg-primary shadow-[0_2px_8px_rgba(0,122,255,0.28)] dark:shadow-none'
          : 'bg-card shadow-[0_1px_2px_rgba(15,23,42,0.06)] dark:shadow-none'
      "
      :style="{
        width: `calc((100% - 8px) / ${items.length})`,
        ...pillStyle
      }"
    />
    <button
      v-for="(item, index) in items"
      data-scrub-item
      :tabindex="index === (tabStop >= 0 ? tabStop : items.findIndex(option => !option.disabled)) ? 0 : -1"
      :style="[itemStyle(index), { '--scrub-color': tone === 'primary' ? 'var(--primary-foreground)' : 'var(--foreground)' }]"
      @keydown="onKeydown($event, index)"
      :key="item.value"
      role="tab"
      type="button"
      :disabled="item.disabled"
      :aria-selected="modelValue === item.value"
      class="pressable relative z-10 flex h-8 items-center justify-center rounded-full px-2 text-[13px] transition-colors disabled:pointer-events-none disabled:opacity-50"
      :class="
        modelValue === item.value
          ? tone === 'primary'
            ? 'font-semibold text-primary-foreground'
            : 'font-semibold text-foreground'
          : 'font-medium text-muted-foreground hover:text-foreground'
      "
      @click="selectItem(item)"
    >
      <span class="truncate">{{ item.label }}</span>
    </button>
  </div>
</template>
