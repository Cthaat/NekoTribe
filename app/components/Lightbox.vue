<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import {
  DialogRoot,
  DialogContent,
  DialogOverlay,
  DialogPortal,
  VisuallyHidden,
  DialogTitle,
  DialogDescription
} from 'radix-vue';
import {
  ChevronLeft,
  ChevronRight,
  X
} from 'lucide-vue-next';

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
}>();

const emit = defineEmits(['update:open']);
const { t } = useAppLocale();

const currentIndex = ref(props.startIndex || 0);

watch(
  () => props.open,
  isOpen => {
    if (isOpen) {
      currentIndex.value = props.startIndex || 0;
    }
  }
);

const currentItem = computed(
  () => props.items[currentIndex.value]
);

const hasMultiple = computed(() => props.items.length > 1);

function next() {
  currentIndex.value =
    (currentIndex.value + 1) % props.items.length;
}

function prev() {
  currentIndex.value =
    (currentIndex.value - 1 + props.items.length) %
    props.items.length;
}

function onKeydown(e: KeyboardEvent) {
  if (!props.open) return;
  if (e.key === 'ArrowRight') {
    e.preventDefault();
    next();
  } else if (e.key === 'ArrowLeft') {
    e.preventDefault();
    prev();
  } else if (e.key === 'Escape') {
    emit('update:open', false);
  }
}
</script>

<template>
  <DialogRoot
    :open="props.open"
    @update:open="value => emit('update:open', value)"
  >
    <DialogPortal>
      <DialogOverlay
        class="fixed inset-0 z-50 bg-black/90 backdrop-blur-sm data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
      />
      <DialogContent
        class="fixed inset-0 z-50 flex items-center justify-center p-4 outline-none data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
        @keydown="onKeydown"
      >
        <VisuallyHidden>
          <DialogTitle>{{ t('media.lightboxAlt') }}</DialogTitle>
          <DialogDescription>{{ currentItem?.description || currentItem?.altText || t('media.lightboxAlt') }}</DialogDescription>
        </VisuallyHidden>

        <!-- Top bar: counter + close -->
        <div
          class="absolute inset-x-0 top-0 z-10 flex h-14 items-center justify-between px-4"
        >
          <div
            v-if="hasMultiple"
            class="rounded-full bg-white/10 px-3 py-1 text-xs font-medium text-white backdrop-blur-md"
          >
            {{ currentIndex + 1 }} / {{ items.length }}
          </div>
          <div v-else />
          <button
            type="button"
            class="inline-flex h-9 w-9 items-center justify-center rounded-full bg-white/10 text-white transition-colors hover:bg-white/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/50"
            @click="emit('update:open', false)"
            aria-label="Close"
          >
            <X class="h-4 w-4" />
          </button>
        </div>

        <!-- Media area -->
        <div class="relative flex h-full w-full items-center justify-center">
          <div class="relative max-h-[88vh] max-w-[92vw]">
            <Transition name="lightbox-fade" mode="out-in">
              <template v-if="currentItem">
                <img
                  v-if="currentItem.type === 'image'"
                  :key="`image-${currentItem.originalUrl}`"
                  :src="currentItem.originalUrl"
                  class="block max-h-[88vh] max-w-[92vw] rounded-lg object-contain shadow-2xl"
                  :alt="currentItem.altText || t('media.lightboxAlt')"
                />
                <video
                  v-else-if="currentItem.type === 'video'"
                  :key="`video-${currentItem.originalUrl}`"
                  :src="currentItem.originalUrl"
                  class="block max-h-[88vh] max-w-[92vw] rounded-lg object-contain shadow-2xl"
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
              v-if="currentItem?.description"
              class="pointer-events-none absolute inset-x-4 bottom-6 mx-auto max-w-2xl rounded-lg bg-black/70 px-4 py-2.5 text-center text-sm text-white backdrop-blur-md"
            >
              {{ currentItem.description }}
            </div>
          </Transition>

          <!-- Prev/Next buttons -->
          <template v-if="hasMultiple">
            <button
              type="button"
              class="absolute left-3 top-1/2 inline-flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white shadow-lg backdrop-blur-md transition-all hover:scale-105 hover:bg-white/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/50 md:left-6"
              @click="prev"
              aria-label="Previous"
            >
              <ChevronLeft class="h-5 w-5" />
            </button>
            <button
              type="button"
              class="absolute right-3 top-1/2 inline-flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white shadow-lg backdrop-blur-md transition-all hover:scale-105 hover:bg-white/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/50 md:right-6"
              @click="next"
              aria-label="Next"
            >
              <ChevronRight class="h-5 w-5" />
            </button>
          </template>

          <!-- Thumbnail strip at bottom -->
          <div
            v-if="hasMultiple"
            class="absolute inset-x-0 bottom-3 z-10 flex justify-center"
          >
            <div
              class="flex gap-1.5 rounded-full bg-white/10 px-2 py-2 backdrop-blur-md"
            >
              <button
                v-for="(item, idx) in items.slice(0, 8)"
                :key="`thumb-${idx}`"
                type="button"
                class="h-2 rounded-full bg-white/40 transition-all hover:bg-white/70"
                :class="
                  idx === currentIndex
                    ? 'w-6 bg-white'
                    : 'w-2'
                "
                @click="currentIndex = idx"
                :aria-label="`Go to slide ${idx + 1}`"
              />
              <span
                v-if="items.length > 8"
                class="self-center px-1 text-[10px] text-white/70"
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
  transition: opacity 0.18s ease;
}
.lightbox-fade-enter-from,
.lightbox-fade-leave-to {
  opacity: 0;
}
</style>
