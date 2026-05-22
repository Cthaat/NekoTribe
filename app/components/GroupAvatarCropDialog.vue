<script setup lang="ts">
import {
  computed,
  ref,
  watch,
  type CSSProperties
} from 'vue';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import { Label } from '@/components/ui/label';
import { Slider } from '@/components/ui/slider';
import {
  Crop,
  Loader2,
  Minus,
  Plus,
  RotateCcw,
  X
} from 'lucide-vue-next';

const props = defineProps<{
  open: boolean;
  sourceUrl: string | null;
  fileName?: string;
  alt?: string;
}>();

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'apply', file: File): void;
}>();

const { t } = useAppLocale();

const CROP_OUTPUT_SIZE = 512;
const DEFAULT_CROP_FRAME_SIZE = 288;
const CROP_MASK_INSET = 24;
const MIN_ZOOM = 1;
const MAX_ZOOM = 3;

const cropFrameRef = ref<HTMLDivElement | null>(null);
const cropImageRef = ref<HTMLImageElement | null>(null);
const imageLoaded = ref(false);
const imageNaturalWidth = ref(0);
const imageNaturalHeight = ref(0);
const cropZoom = ref(1);
const cropOffset = ref({ x: 0, y: 0 });
const isDragging = ref(false);

let dragStartX = 0;
let dragStartY = 0;
let dragStartOffsetX = 0;
let dragStartOffsetY = 0;

const cropImageStyle = computed<CSSProperties>(() => {
  if (!imageLoaded.value) return {};

  const scale = getDisplayScale();
  return {
    width: `${imageNaturalWidth.value * scale}px`,
    height: `${imageNaturalHeight.value * scale}px`,
    transform: `translate(calc(-50% + ${cropOffset.value.x}px), calc(-50% + ${cropOffset.value.y}px))`
  };
});

const zoomValue = computed<number[]>({
  get: () => [cropZoom.value],
  set: value => {
    setZoom(value?.[0] ?? cropZoom.value);
  }
});

const zoomPercent = computed(
  () => `${Math.round(cropZoom.value * 100)}%`
);

const cropMaskStyle = computed<CSSProperties>(() => ({
  inset: `${CROP_MASK_INSET}px`
}));

function updateOpen(value: boolean): void {
  emit('update:open', value);
}

function resetCropState(): void {
  imageLoaded.value = false;
  imageNaturalWidth.value = 0;
  imageNaturalHeight.value = 0;
  cropZoom.value = 1;
  cropOffset.value = { x: 0, y: 0 };
  isDragging.value = false;
}

function getCropBoxSize(): number {
  const frameSize =
    cropFrameRef.value?.clientWidth ?? DEFAULT_CROP_FRAME_SIZE;
  return Math.max(1, frameSize - CROP_MASK_INSET * 2);
}

function getCropBoxInset(): number {
  const frameSize =
    cropFrameRef.value?.clientWidth ?? DEFAULT_CROP_FRAME_SIZE;
  return Math.max(0, (frameSize - getCropBoxSize()) / 2);
}

function getCropFrameCenter(): number {
  return (
    (cropFrameRef.value?.clientWidth ?? DEFAULT_CROP_FRAME_SIZE) /
    2
  );
}

function getBaseScale(): number {
  if (
    !imageNaturalWidth.value ||
    !imageNaturalHeight.value
  ) {
    return 1;
  }

  const cropBoxSize = getCropBoxSize();
  return Math.max(
    cropBoxSize / imageNaturalWidth.value,
    cropBoxSize / imageNaturalHeight.value
  );
}

function getDisplayScale(): number {
  return getBaseScale() * cropZoom.value;
}

function clamp(
  value: number,
  min: number,
  max: number
): number {
  return Math.min(Math.max(value, min), max);
}

function clampCropOffset(
  nextOffset = cropOffset.value
): { x: number; y: number } {
  const cropBoxSize = getCropBoxSize();
  const scale = getDisplayScale();
  const displayWidth = imageNaturalWidth.value * scale;
  const displayHeight = imageNaturalHeight.value * scale;
  const maxX = Math.max(0, (displayWidth - cropBoxSize) / 2);
  const maxY = Math.max(
    0,
    (displayHeight - cropBoxSize) / 2
  );
  const clampedOffset = {
    x: clamp(nextOffset.x, -maxX, maxX),
    y: clamp(nextOffset.y, -maxY, maxY)
  };
  cropOffset.value = clampedOffset;
  return clampedOffset;
}

function handleImageLoad(event: Event): void {
  const image = event.target as HTMLImageElement;
  imageNaturalWidth.value = image.naturalWidth;
  imageNaturalHeight.value = image.naturalHeight;
  imageLoaded.value = true;
  cropZoom.value = 1;
  cropOffset.value = { x: 0, y: 0 };
  requestAnimationFrame(() => clampCropOffset());
}

function handleImageError(): void {
  toast.error(t('avatar.feedback.uploadFailed'));
  updateOpen(false);
}

function startDrag(event: PointerEvent): void {
  if (!imageLoaded.value) return;
  isDragging.value = true;
  dragStartX = event.clientX;
  dragStartY = event.clientY;
  dragStartOffsetX = cropOffset.value.x;
  dragStartOffsetY = cropOffset.value.y;
  (event.currentTarget as HTMLElement).setPointerCapture(
    event.pointerId
  );
  event.preventDefault();
}

function dragCrop(event: PointerEvent): void {
  if (!isDragging.value) return;
  clampCropOffset({
    x: dragStartOffsetX + event.clientX - dragStartX,
    y: dragStartOffsetY + event.clientY - dragStartY
  });
}

function stopDrag(event: PointerEvent): void {
  if (!isDragging.value) return;
  isDragging.value = false;
  const target = event.currentTarget as HTMLElement;
  if (target.hasPointerCapture(event.pointerId)) {
    target.releasePointerCapture(event.pointerId);
  }
}

function setZoom(value: number): void {
  cropZoom.value = clamp(value, MIN_ZOOM, MAX_ZOOM);
  clampCropOffset();
}

function stepZoom(direction: -1 | 1): void {
  setZoom(cropZoom.value + direction * 0.12);
}

function resetCropTransform(): void {
  if (!imageLoaded.value) return;
  cropZoom.value = MIN_ZOOM;
  cropOffset.value = { x: 0, y: 0 };
  requestAnimationFrame(() => clampCropOffset());
}

function handleWheelZoom(event: WheelEvent): void {
  if (!imageLoaded.value) return;
  const delta = event.deltaY < 0 ? 0.08 : -0.08;
  setZoom(cropZoom.value + delta);
}

function createCroppedAvatarBlob(): Promise<Blob> {
  return new Promise((resolve, reject) => {
    const image = cropImageRef.value;
    if (!image || !imageLoaded.value) {
      reject(new Error('Image is not ready.'));
      return;
    }

    const cropFrameCenter = getCropFrameCenter();
    const cropBoxSize = getCropBoxSize();
    const cropBoxInset = getCropBoxInset();
    const scale = getDisplayScale();
    const displayWidth = imageNaturalWidth.value * scale;
    const displayHeight = imageNaturalHeight.value * scale;
    const imageLeft =
      cropFrameCenter + cropOffset.value.x - displayWidth / 2;
    const imageTop =
      cropFrameCenter + cropOffset.value.y - displayHeight / 2;
    const sourceSize = cropBoxSize / scale;
    const sourceX = clamp(
      (cropBoxInset - imageLeft) / scale,
      0,
      Math.max(0, imageNaturalWidth.value - sourceSize)
    );
    const sourceY = clamp(
      (cropBoxInset - imageTop) / scale,
      0,
      Math.max(0, imageNaturalHeight.value - sourceSize)
    );

    const canvas = document.createElement('canvas');
    canvas.width = CROP_OUTPUT_SIZE;
    canvas.height = CROP_OUTPUT_SIZE;
    const context = canvas.getContext('2d');

    if (!context) {
      reject(new Error('Canvas is not available.'));
      return;
    }

    context.drawImage(
      image,
      sourceX,
      sourceY,
      sourceSize,
      sourceSize,
      0,
      0,
      CROP_OUTPUT_SIZE,
      CROP_OUTPUT_SIZE
    );

    canvas.toBlob(
      blob => {
        if (blob) {
          resolve(blob);
          return;
        }
        reject(new Error('Failed to crop avatar.'));
      },
      'image/jpeg',
      0.92
    );
  });
}

function buildCroppedFile(blob: Blob): File {
  const rawName =
    props.fileName?.replace(/\.[^.]+$/, '') || 'avatar';
  return new File([blob], `${rawName}-cropped.jpg`, {
    type: 'image/jpeg'
  });
}

async function applyCrop(): Promise<void> {
  try {
    const blob = await createCroppedAvatarBlob();
    emit('apply', buildCroppedFile(blob));
  } catch (error) {
    toast.error(t('avatar.feedback.uploadFailed'));
  }
}

watch(
  () => props.open,
  open => {
    if (!open) resetCropState();
  }
);
</script>

<template>
  <Dialog :open="open" @update:open="updateOpen">
    <DialogContent
      class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-xl"
    >
      <DialogHeader
        class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
      >
        <DialogTitle
          class="flex items-center gap-2 text-base font-semibold tracking-tight"
        >
          <span
            class="flex h-7 w-7 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <Crop class="h-4 w-4" />
          </span>
          {{ t('avatar.crop.title') }}
        </DialogTitle>
      </DialogHeader>

      <div class="grid gap-4 px-5 py-4">
        <div
          ref="cropFrameRef"
          class="relative mx-auto aspect-square w-full max-w-80 touch-none select-none overflow-hidden rounded-xl border border-border/60 bg-muted/40 shadow-inner"
          :class="
            imageLoaded
              ? isDragging
                ? 'cursor-grabbing'
                : 'cursor-grab'
              : 'cursor-default'
          "
          @pointerdown="startDrag"
          @pointermove="dragCrop"
          @pointerup="stopDrag"
          @pointercancel="stopDrag"
          @lostpointercapture="isDragging = false"
          @wheel.prevent="handleWheelZoom"
        >
          <img
            v-if="sourceUrl"
            ref="cropImageRef"
            :src="sourceUrl"
            :alt="alt || t('groups.manage.fields.avatar')"
            class="absolute left-1/2 top-1/2 max-w-none select-none"
            :style="cropImageStyle"
            draggable="false"
            @load="handleImageLoad"
            @error="handleImageError"
          />
          <div
            v-if="!imageLoaded"
            class="absolute inset-0 flex items-center justify-center"
          >
            <Loader2
              class="h-5 w-5 animate-spin text-muted-foreground"
            />
          </div>
          <div
            class="pointer-events-none absolute rounded-full border-2 border-background/95 shadow-[0_0_0_999px_rgba(0,0,0,0.42)]"
            :style="cropMaskStyle"
          />
          <div
            class="pointer-events-none absolute inset-0 ring-1 ring-inset ring-border/70"
          />
        </div>

        <div
          class="grid gap-3 rounded-xl border border-border/60 bg-muted/20 p-3"
        >
          <div class="flex items-center justify-between gap-3">
            <Label
              for="group-avatar-crop-zoom"
              class="text-xs font-medium"
            >
              {{ t('avatar.crop.zoom') }}
            </Label>
            <span
              class="rounded-full border border-border/60 bg-background/80 px-2 py-0.5 text-[11px] font-medium tabular-nums text-muted-foreground"
            >
              {{ zoomPercent }}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="button"
              class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
              :disabled="!imageLoaded"
              @click.stop="stepZoom(-1)"
            >
              <Minus class="h-3.5 w-3.5" />
              <span class="sr-only">{{
                t('avatar.crop.zoomOut')
              }}</span>
            </button>
            <Slider
              id="group-avatar-crop-zoom"
              v-model="zoomValue"
              class="flex-1"
              :min="MIN_ZOOM"
              :max="MAX_ZOOM"
              :step="0.01"
              :disabled="!imageLoaded"
              :aria-label="t('avatar.crop.zoom')"
            />
            <button
              type="button"
              class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
              :disabled="!imageLoaded"
              @click.stop="stepZoom(1)"
            >
              <Plus class="h-3.5 w-3.5" />
              <span class="sr-only">{{
                t('avatar.crop.zoomIn')
              }}</span>
            </button>
          </div>
          <div class="flex justify-end">
            <button
              type="button"
              class="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-[11px] font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
              :disabled="!imageLoaded"
              @click="resetCropTransform"
            >
              <RotateCcw class="h-3 w-3" />
              {{ t('avatar.crop.reset') }}
            </button>
          </div>
        </div>
      </div>

      <DialogFooter
        class="flex flex-col-reverse gap-2 border-t border-border/60 bg-background/60 px-5 py-3 backdrop-blur sm:flex-row sm:justify-end"
      >
        <Button
          type="button"
          variant="outline"
          class="h-9 rounded-md shadow-xs"
          @click="updateOpen(false)"
        >
          <X class="h-3.5 w-3.5" />
          {{ t('common.cancel') }}
        </Button>
        <Button
          type="button"
          class="h-9 rounded-md shadow-xs"
          :disabled="!imageLoaded"
          @click="applyCrop"
        >
          <Crop class="h-3.5 w-3.5" />
          {{ t('avatar.crop.apply') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
