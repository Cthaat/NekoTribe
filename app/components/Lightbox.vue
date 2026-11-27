<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue';
import {
  DialogContent,
  DialogDescription,
  DialogOverlay,
  DialogPortal,
  DialogRoot,
  DialogTitle,
  VisuallyHidden
} from 'reka-ui';
import {
  ChevronLeft,
  ChevronRight,
  ExternalLink,
  RotateCcw,
  X,
  ZoomIn,
  ZoomOut
} from 'lucide-vue-next';

export interface LightboxOriginRect {
  top: number;
  left: number;
  width: number;
  height: number;
}

interface MediaItem {
  type: 'image' | 'video';
  originalUrl: string;
  thumbnailUrl: string;
  altText?: string | null;
  description?: string | null;
}

const props = defineProps<{
  items: MediaItem[];
  startIndex?: number;
  open: boolean;
  originRect?: LightboxOriginRect | null;
}>();

const emit = defineEmits(['update:open']);
const { t } = useAppLocale();

const currentIndex = ref(props.startIndex || 0);
const stageRef = ref<HTMLElement | null>(null);
const flipTransform = ref('');
const flipActive = ref(false);
const isClosing = ref(false);

const zoomScale = ref(1);
const panX = ref(0);
const panY = ref(0);
const dragY = ref(0);
const isDragging = ref(false);
const isPanning = ref(false);
let dragStartY = 0;
let dragStartX = 0;
let panStartX = 0;
let panStartY = 0;
let activePointerId: number | null = null;
let flipRaf: number | null = null;

function prefersReducedMotion(): boolean {
  if (typeof window === 'undefined' || !window.matchMedia) return false;
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

function resetTransformState(): void {
  zoomScale.value = 1;
  panX.value = 0;
  panY.value = 0;
  dragY.value = 0;
  isDragging.value = false;
  isPanning.value = false;
  activePointerId = null;
}

function computeFlipDelta(rect: LightboxOriginRect | null | undefined, el: HTMLElement | null): string {
  if (!rect || !el || rect.width <= 0 || rect.height <= 0) return '';
  const target = el.getBoundingClientRect();
  if (target.width <= 0 || target.height <= 0) return '';
  const originCenterX = rect.left + rect.width / 2;
  const originCenterY = rect.top + rect.height / 2;
  const targetCenterX = target.left + target.width / 2;
  const targetCenterY = target.top + target.height / 2;
  const dx = originCenterX - targetCenterX;
  const dy = originCenterY - targetCenterY;
  const scale = Math.max(0.18, Math.min(0.95, Math.min(rect.width / target.width, rect.height / target.height)));
  return `translate3d(${dx.toFixed(1)}px, ${dy.toFixed(1)}px, 0) scale(${scale.toFixed(3)})`;
}

async function runOpenFlip(): Promise<void> {
  if (prefersReducedMotion() || !props.originRect) {
    flipActive.value = false;
    flipTransform.value = '';
    return;
  }
  await nextTick();
  const initial = computeFlipDelta(props.originRect, stageRef.value);
  if (!initial) {
    flipActive.value = false;
    flipTransform.value = '';
    return;
  }
  flipActive.value = false;
  flipTransform.value = initial;
  flipRaf = requestAnimationFrame(() => {
    flipRaf = requestAnimationFrame(() => {
      flipActive.value = true;
      flipTransform.value = 'translate3d(0px, 0px, 0) scale(1)';
    });
  });
}

function cancelFlipAnimation(): void {
  if (flipRaf !== null) {
    cancelAnimationFrame(flipRaf);
    flipRaf = null;
  }
}

watch(
  () => props.open,
  isOpen => {
    cancelFlipAnimation();
    resetTransformState();
    isClosing.value = false;
    if (isOpen) {
      currentIndex.value = Math.max(0, Math.min(props.startIndex || 0, Math.max(0, props.items.length - 1)));
      void runOpenFlip();
    } else {
      flipActive.value = false;
      flipTransform.value = '';
    }
  }
);

watch(currentIndex, () => {
  resetTransformState();
  flipActive.value = false;
  flipTransform.value = '';
});

onBeforeUnmount(() => {
  cancelFlipAnimation();
});

const currentItem = computed(() => props.items[currentIndex.value]);
const hasMultiple = computed(() => props.items.length > 1);
const isImage = computed(() => currentItem.value?.type === 'image');

const backdropOpacity = computed(() => {
  if (isClosing.value) return 0;
  const dragRatio = Math.min(Math.abs(dragY.value) / 360, 1);
  return Math.max(0.24, 0.92 * (1 - dragRatio * 0.72));
});

const mediaSurfaceStyle = computed(() => {
  if (flipTransform.value && !isDragging.value && zoomScale.value === 1) {
    return {
      transform: flipTransform.value,
      transition: flipActive.value && !prefersReducedMotion()
        ? 'transform 260ms var(--ease-spring)'
        : 'none'
    };
  }
  const dragScale = zoomScale.value === 1 && dragY.value !== 0
    ? Math.max(0.84, 1 - Math.abs(dragY.value) / 900)
    : 1;
  const translateX = zoomScale.value > 1 ? panX.value : 0;
  const translateY = zoomScale.value > 1 ? panY.value : dragY.value;
  const combinedScale = zoomScale.value * dragScale;
  return {
    transform: `translate3d(${translateX}px, ${translateY}px, 0) scale(${combinedScale})`,
    transition: isDragging.value || isPanning.value || prefersReducedMotion()
      ? 'none'
      : 'transform 240ms var(--ease-spring)'
  };
});

function closeLightbox(): void {
  if (isClosing.value) return;
  if (!prefersReducedMotion() && props.originRect && zoomScale.value === 1) {
    const targetDelta = computeFlipDelta(props.originRect, stageRef.value);
    if (targetDelta) {
      isClosing.value = true;
      flipActive.value = true;
      flipTransform.value = targetDelta;
      setTimeout(() => {
        isClosing.value = false;
        emit('update:open', false);
      }, 170);
      return;
    }
  }
  emit('update:open', false);
}

function next(): void {
  if (!hasMultiple.value) return;
  currentIndex.value = (currentIndex.value + 1) % props.items.length;
}

function prev(): void {
  if (!hasMultiple.value) return;
  currentIndex.value = (currentIndex.value - 1 + props.items.length) % props.items.length;
}

function setZoom(nextScale: number): void {
  if (!isImage.value) return;
  const clamped = Math.max(1, Math.min(2.5, Number(nextScale.toFixed(2))));
  zoomScale.value = clamped;
  dragY.value = 0;
  if (clamped === 1) {
    panX.value = 0;
    panY.value = 0;
  }
}

function toggleDoubleZoom(): void {
  if (!isImage.value) return;
  setZoom(zoomScale.value > 1.05 ? 1 : 2);
}

function onWheel(event: WheelEvent): void {
  if (!props.open || !isImage.value) return;
  if (!event.ctrlKey && !event.metaKey && zoomScale.value === 1) return;
  event.preventDefault();
  const step = event.deltaY < 0 ? 0.25 : -0.25;
  setZoom(zoomScale.value + step);
}

function onPointerDown(event: PointerEvent): void {
  if (!isImage.value || event.button !== 0) return;
  flipTransform.value = '';
  flipActive.value = false;
  activePointerId = event.pointerId;
  dragStartX = event.clientX;
  dragStartY = event.clientY;
  panStartX = panX.value;
  panStartY = panY.value;
  (event.currentTarget as HTMLElement | null)?.setPointerCapture?.(event.pointerId);
  if (zoomScale.value > 1.02) {
    isPanning.value = true;
  } else {
    isDragging.value = true;
  }
}

function onPointerMove(event: PointerEvent): void {
  if (activePointerId !== event.pointerId) return;
  if (isPanning.value) {
    panX.value = panStartX + (event.clientX - dragStartX);
    panY.value = panStartY + (event.clientY - dragStartY);
    return;
  }
  if (isDragging.value) {
    const dy = event.clientY - dragStartY;
    const dx = event.clientX - dragStartX;
    if (Math.abs(dy) >= Math.abs(dx) * 0.8 || Math.abs(dragY.value) > 4) {
      dragY.value = dy;
    }
  }
}

function onPointerUp(event: PointerEvent): void {
  if (activePointerId !== event.pointerId) return;
  (event.currentTarget as HTMLElement | null)?.releasePointerCapture?.(event.pointerId);
  activePointerId = null;
  if (isPanning.value) {
    isPanning.value = false;
    return;
  }
  if (isDragging.value) {
    const dy = dragY.value;
    isDragging.value = false;
    if (Math.abs(dy) > 110) {
      closeLightbox();
      return;
    }
    dragY.value = 0;
  }
}

function onKeydown(e: KeyboardEvent): void {
  if (!props.open) return;
  if (e.key === 'ArrowRight') {
    e.preventDefault();
    next();
  } else if (e.key === 'ArrowLeft') {
    e.preventDefault();
    prev();
  } else if (e.key === '+' || e.key === '=') {
    e.preventDefault();
    setZoom(zoomScale.value + 0.5);
  } else if (e.key === '-') {
    e.preventDefault();
    setZoom(zoomScale.value - 0.5);
  } else if (e.key === '0') {
    e.preventDefault();
    setZoom(1);
  } else if (e.key === 'Escape') {
    e.preventDefault();
    closeLightbox();
  }
}
</script>

<template>
  <DialogRoot
    :open="props.open"
    @update:open="value => { if (!value) closeLightbox(); else emit('update:open', true); }"
  >
    <DialogPortal>
      <DialogOverlay
        class="fixed inset-0 z-50 backdrop-blur-md transition-opacity duration-200"
        :style="{ backgroundColor: `rgba(6, 9, 14, ${backdropOpacity})` }"
      />
      <DialogContent
        class="fixed inset-0 z-50 flex items-center justify-center p-4 outline-none"
        @keydown="onKeydown"
        @click.self="closeLightbox"
      >
        <VisuallyHidden>
          <DialogTitle>{{ t('media.lightboxAlt') }}</DialogTitle>
          <DialogDescription>{{ currentItem?.description || currentItem?.altText || t('media.lightboxAlt') }}</DialogDescription>
        </VisuallyHidden>

        <!-- Liquid Glass top chrome bar -->
        <div
          class="pointer-events-none absolute inset-x-0 top-0 z-20 flex h-16 items-center justify-between px-4 sm:px-6"
        >
          <div class="pointer-events-auto flex items-center gap-2">
            <div
              v-if="hasMultiple"
              class="rounded-full bg-black/45 px-3.5 py-1.5 text-xs font-medium tabular-nums text-white ring-1 ring-white/20 backdrop-blur-xl"
            >
              {{ currentIndex + 1 }} / {{ items.length }}
            </div>
          </div>

          <div class="pointer-events-auto flex items-center gap-1.5">
            <template v-if="isImage">
              <button
                type="button"
                class="pressable inline-flex size-9 items-center justify-center rounded-full bg-black/45 text-white ring-1 ring-white/20 backdrop-blur-xl transition-colors hover:bg-white/20"
                :aria-label="t('lightbox.zoomOut')"
                :title="t('lightbox.zoomOut')"
                :disabled="zoomScale <= 1"
                @click="setZoom(zoomScale - 0.5)"
              >
                <ZoomOut class="size-4" />
              </button>
              <button
                type="button"
                class="pressable inline-flex size-9 items-center justify-center rounded-full bg-black/45 text-white ring-1 ring-white/20 backdrop-blur-xl transition-colors hover:bg-white/20"
                :aria-label="t('lightbox.zoomIn')"
                :title="t('lightbox.zoomIn')"
                :disabled="zoomScale >= 2.5"
                @click="setZoom(zoomScale + 0.5)"
              >
                <ZoomIn class="size-4" />
              </button>
              <button
                v-if="zoomScale > 1.05"
                type="button"
                class="pressable inline-flex size-9 items-center justify-center rounded-full bg-black/45 text-white ring-1 ring-white/20 backdrop-blur-xl transition-colors hover:bg-white/20"
                :aria-label="t('lightbox.resetZoom')"
                :title="t('lightbox.resetZoom')"
                @click="setZoom(1)"
              >
                <RotateCcw class="size-4" />
              </button>
            </template>

            <a
              v-if="currentItem?.originalUrl"
              :href="currentItem.originalUrl"
              target="_blank"
              rel="noreferrer noopener"
              class="pressable inline-flex size-9 items-center justify-center rounded-full bg-black/45 text-white ring-1 ring-white/20 backdrop-blur-xl transition-colors hover:bg-white/20"
              :aria-label="t('lightbox.openOriginal')"
              :title="t('lightbox.openOriginal')"
            >
              <ExternalLink class="size-4" />
            </a>

            <button
              type="button"
              class="pressable inline-flex size-9 items-center justify-center rounded-full bg-black/45 text-white ring-1 ring-white/20 backdrop-blur-xl transition-colors hover:bg-white/20"
              :aria-label="t('common.close')"
              :title="t('common.close')"
              @click="closeLightbox"
            >
              <X class="size-4" />
            </button>
          </div>
        </div>

        <!-- Media canvas -->
        <div
          class="relative flex h-full w-full items-center justify-center select-none"
          @click.self="closeLightbox"
        >
          <div
            ref="stageRef"
            class="relative flex max-h-[86vh] max-w-[92vw] touch-none items-center justify-center will-change-transform"
            :class="zoomScale > 1 ? 'cursor-grab active:cursor-grabbing' : 'cursor-zoom-in'"
            :style="mediaSurfaceStyle"
            @dblclick.stop="toggleDoubleZoom"
            @wheel="onWheel"
            @pointerdown="onPointerDown"
            @pointermove="onPointerMove"
            @pointerup="onPointerUp"
            @pointercancel="onPointerUp"
          >
            <Transition name="lightbox-fade" mode="out-in">
              <template v-if="currentItem">
                <img
                  v-if="currentItem.type === 'image'"
                  :key="`image-${currentItem.originalUrl}`"
                  :src="currentItem.originalUrl"
                  draggable="false"
                  class="block max-h-[86vh] max-w-[92vw] rounded-[18px] object-contain shadow-2xl select-none"
                  :alt="currentItem.altText || t('media.lightboxAlt')"
                />
                <video
                  v-else-if="currentItem.type === 'video'"
                  :key="`video-${currentItem.originalUrl}`"
                  :src="currentItem.originalUrl"
                  class="block max-h-[86vh] max-w-[92vw] rounded-[18px] object-contain shadow-2xl"
                  controls
                  autoplay
                  loop
                />
              </template>
            </Transition>
          </div>

          <!-- Caption -->
          <Transition name="lightbox-fade">
            <div
              v-if="currentItem?.description || currentItem?.altText"
              class="pointer-events-none absolute inset-x-4 mx-auto max-w-2xl rounded-2xl bg-black/55 px-4 py-2.5 text-center text-sm text-white/95 ring-1 ring-white/15 backdrop-blur-xl"
              :class="hasMultiple ? 'bottom-16' : 'bottom-6'"
            >
              {{ currentItem.description || currentItem.altText }}
            </div>
          </Transition>

          <!-- Prev/Next glass buttons -->
          <template v-if="hasMultiple">
            <button
              type="button"
              class="pressable absolute left-3 top-1/2 z-20 inline-flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-full bg-black/45 text-white ring-1 ring-white/20 shadow-lg backdrop-blur-xl transition-colors hover:bg-white/20 md:left-6"
              :aria-label="t('common.previousMedia')"
              @click.stop="prev"
            >
              <ChevronLeft class="h-5 w-5" />
            </button>
            <button
              type="button"
              class="pressable absolute right-3 top-1/2 z-20 inline-flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-full bg-black/45 text-white ring-1 ring-white/20 shadow-lg backdrop-blur-xl transition-colors hover:bg-white/20 md:right-6"
              :aria-label="t('common.nextMedia')"
              @click.stop="next"
            >
              <ChevronRight class="h-5 w-5" />
            </button>
          </template>

          <!-- Liquid Glass thumbnail strip -->
          <div
            v-if="hasMultiple"
            class="absolute inset-x-0 bottom-3 z-20 flex justify-center"
          >
            <div
              class="flex items-center gap-1.5 rounded-full bg-black/45 px-2.5 py-2 ring-1 ring-white/20 backdrop-blur-xl"
            >
              <button
                v-for="(item, idx) in items.slice(0, 8)"
                :key="`thumb-${idx}`"
                type="button"
                class="h-2 rounded-full bg-white/40 transition-all hover:bg-white/75"
                :class="idx === currentIndex ? 'w-6 bg-white' : 'w-2'"
                :aria-label="t('common.viewMedia', { index: idx + 1 })"
                :aria-pressed="currentIndex === idx"
                @click.stop="currentIndex = idx"
              />
              <span
                v-if="items.length > 8"
                class="self-center px-1 text-[10px] font-medium text-white/75"
              >
                +{{ items.length - 8 }}
              </span>
            </div>
          </div>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>

<style scoped>
.lightbox-fade-enter-active,
.lightbox-fade-leave-active {
  transition: opacity 0.16s ease;
}
.lightbox-fade-enter-from,
.lightbox-fade-leave-to {
  opacity: 0;
}
</style>
