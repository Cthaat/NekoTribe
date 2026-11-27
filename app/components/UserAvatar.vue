<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { PawPrint } from 'lucide-vue-next';

const props = withDefaults(
  defineProps<{
    src?: string | null;
    name?: string | null;
    username?: string | null;
    seed?: number | string | null;
    size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl';
  }>(),
  {
    src: '',
    name: '',
    username: '',
    seed: null,
    size: 'md'
  }
);

const imgFailed = ref(false);

watch(() => props.src, () => {
  imgFailed.value = false;
});

const sizeClass = computed(() => {
  switch (props.size) {
    case 'xs':
      return 'size-6 text-[10px]';
    case 'sm':
      return 'size-8 text-xs';
    case 'md':
      return 'size-10 text-sm';
    case 'lg':
      return 'size-14 text-lg';
    case 'xl':
      return 'size-24 text-3xl';
  }
});

const hasImage = computed(() => {
  const s = (props.src || '').trim();
  return (
    s.length > 0 &&
    !s.endsWith('/avatars/shadcn.jpg') &&
    !/\/default-avatar\.(png|jpe?g|webp|svg|gif)(\?.*)?$/i.test(s) &&
    !imgFailed.value
  );
});

const displaySource = computed(() => (props.name || props.username || '').trim());

const initial = computed(() => {
  const raw = displaySource.value.replace(/^@/, '');
  if (!raw) return '';
  return Array.from(raw)[0]?.toUpperCase() ?? '';
});

const TONE_CLASSES = [
  'bg-secondary text-foreground/80',
  'bg-[color-mix(in_srgb,var(--secondary)_88%,var(--primary)_12%)] text-foreground/85',
  'bg-accent text-foreground/80',
  'bg-[color-mix(in_srgb,var(--secondary)_92%,var(--foreground)_8%)] text-foreground/80'
] as const;

const toneClass = computed(() => {
  let idx = 0;
  const numericSeed = Number(props.seed);
  if (Number.isFinite(numericSeed) && numericSeed > 0) {
    idx = Math.abs(Math.trunc(numericSeed)) % TONE_CLASSES.length;
  } else if (displaySource.value) {
    let hash = 0;
    for (let i = 0; i < displaySource.value.length; i++) {
      hash = (hash * 31 + displaySource.value.charCodeAt(i)) & 0x7fffffff;
    }
    idx = hash % TONE_CLASSES.length;
  }
  return TONE_CLASSES[idx]!;
});
</script>

<template>
  <span
    :class="[sizeClass, !hasImage ? toneClass : '']"
    class="relative inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full select-none"
  >
    <img
      v-if="hasImage"
      :src="props.src!"
      :alt="props.name || props.username || 'avatar'"
      class="size-full object-cover"
      @error="imgFailed = true"
    />
    <span v-else-if="initial" class="font-semibold leading-none">
      {{ initial }}
    </span>
    <PawPrint v-else class="size-1/2 opacity-60" aria-hidden="true" />
  </span>
</template>
