<script setup lang="ts">
import {
  computed,
  onBeforeUnmount,
  ref,
  watch,
  type CSSProperties,
  type PropType
} from 'vue';
import { toast } from 'vue-sonner';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
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
  Loader2,
  Minus,
  Plus,
  RotateCcw
} from 'lucide-vue-next';
import { v2UpdateAvatar } from '@/services';
import { usePreferenceStore } from '~/stores/user';

const { t } = useAppLocale();

const props = defineProps({
  user: {
    type: Object as PropType<{
      name: string;
      avatar: string;
    }>,
    required: true
  }
});

const emit = defineEmits<{
  (event: 'update:avatar', value: string): void;
}>();

const CROP_OUTPUT_SIZE = 512;
const DEFAULT_CROP_FRAME_SIZE = 288;
const CROP_MASK_INSET = 24;
const MIN_ZOOM = 1;
const MAX_ZOOM = 3;

const fileInputRef = ref<HTMLInputElement | null>(null);
const cropFrameRef = ref<HTMLDivElement | null>(null);
const cropImageRef = ref<HTMLImageElement | null>(null);
const isUploading = ref(false);
const previewUrl = ref<string | null>(null);
const sourceImageUrl = ref<string | null>(null);
const selectedFileName = ref('avatar.jpg');
const cropDialogOpen = ref(false);
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

const displayAvatarUrl = computed(() => {
  return previewUrl.value || props.user.avatar;
});

const cropImageStyle = computed<CSSProperties>(() => {
  if (!imageLoaded.value) {
    return {};
  }

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

const zoomPercent = computed(() => {
  return `${Math.round(cropZoom.value * 100)}%`;
});

const cropMaskStyle = computed<CSSProperties>(() => ({
  inset: `${CROP_MASK_INSET}px`
}));

function triggerFileUpload(): void {
  if (isUploading.value || cropDialogOpen.value) return;
  fileInputRef.value?.click();
}

function revokeObjectUrl(url: string | null): void {
  if (url) {
    URL.revokeObjectURL(url);
  }
}

function resetFileInput(): void {
  if (fileInputRef.value) {
    fileInputRef.value.value = '';
  }
}

function resetCropState(): void {
  imageLoaded.value = false;
  imageNaturalWidth.value = 0;
  imageNaturalHeight.value = 0;
  cropZoom.value = 1;
  cropOffset.value = { x: 0, y: 0 };
  isDragging.value = false;
}

function clearCropSource(): void {
  revokeObjectUrl(sourceImageUrl.value);
  sourceImageUrl.value = null;
  resetCropState();
}

function setPreviewUrl(url: string | null): void {
  revokeObjectUrl(previewUrl.value);
  previewUrl.value = url;
}

function openCropDialog(file: File): void {
  clearCropSource();
  selectedFileName.value = file.name || 'avatar.jpg';
  sourceImageUrl.value = URL.createObjectURL(file);
  cropDialogOpen.value = true;
}

function closeCropDialog(): void {
  cropDialogOpen.value = false;
}

function onFileSelected(event: Event): void {
  const target = event.target as HTMLInputElement;
  const file = target.files?.[0];

  if (!file) {
    return;
  }

  const maxSizeInMB = 5;
  if (file.size > maxSizeInMB * 1024 * 1024) {
    toast.error(
      t('avatar.validation.maxSize', { size: maxSizeInMB })
    );
    resetFileInput();
    return;
  }

  openCropDialog(file);
  resetFileInput();
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
  closeCropDialog();
}

function startDrag(event: PointerEvent): void {
  if (!imageLoaded.value || isUploading.value) return;
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
  if (!imageLoaded.value || isUploading.value) return;
  cropZoom.value = MIN_ZOOM;
  cropOffset.value = { x: 0, y: 0 };
  requestAnimationFrame(() => clampCropOffset());
}

function handleWheelZoom(event: WheelEvent): void {
  if (!imageLoaded.value || isUploading.value) return;
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
    selectedFileName.value.replace(/\.[^.]+$/, '') ||
    'avatar';
  return new File([blob], `${rawName}-cropped.jpg`, {
    type: 'image/jpeg'
  });
}

async function applyCrop(): Promise<void> {
  try {
    const blob = await createCroppedAvatarBlob();
    const croppedFile = buildCroppedFile(blob);
    closeCropDialog();
    setPreviewUrl(URL.createObjectURL(croppedFile));
    await uploadAvatar(croppedFile);
  } catch (error) {
    console.error(t('avatar.feedback.uploadFailed'), error);
    toast.error(t('avatar.feedback.uploadFailed'));
  }
}

async function uploadAvatar(file: File): Promise<void> {
  isUploading.value = true;

  const formData = new FormData();
  formData.append('avatar', file);

  try {
    const response = await v2UpdateAvatar(formData);
    if (response.avatarUrl) {
      emit('update:avatar', response.avatarUrl);
      const preferenceStore = usePreferenceStore();
      preferenceStore.updatePreference('user', {
        ...preferenceStore.preferences.user,
        avatarUrl: response.avatarUrl
      });
      if (process.client) {
        window.location.reload();
      }
      toast(t('avatar.feedback.updated'));
    } else {
      throw new Error(
        'API did not return a new avatar URL.'
      );
    }
  } catch (error) {
    console.error(t('avatar.feedback.uploadFailed'), error);
    toast.error(t('avatar.feedback.uploadFailed'));
    setPreviewUrl(null);
  } finally {
    isUploading.value = false;
  }
}

watch(cropDialogOpen, open => {
  if (!open) {
    clearCropSource();
  }
});

onBeforeUnmount(() => {
  clearCropSource();
  setPreviewUrl(null);
});
</script>

<template>
  <div
    class="relative cursor-pointer"
    @click="triggerFileUpload"
  >
    <Avatar class="h-24 w-24 border">
      <AvatarImage
        :src="displayAvatarUrl"
        :alt="user.name"
      />
      <AvatarFallback>{{
        user.name?.slice(0, 2).toUpperCase()
      }}</AvatarFallback>
    </Avatar>

    <div
      v-if="isUploading"
      class="absolute inset-0 flex items-center justify-center rounded-full bg-black/50"
    >
      <Loader2 class="size-8 animate-spin text-white" />
    </div>

    <input
      ref="fileInputRef"
      type="file"
      class="hidden"
      accept="image/png, image/jpeg, image/gif"
      @change="onFileSelected"
    />
  </div>

  <Dialog v-model:open="cropDialogOpen">
    <DialogContent class="sm:max-w-xl">
      <DialogHeader>
        <DialogTitle>{{ t('avatar.crop.title') }}</DialogTitle>
      </DialogHeader>

      <div class="space-y-5">
        <div
          ref="cropFrameRef"
          class="relative mx-auto aspect-square w-full max-w-80 touch-none select-none overflow-hidden rounded-md border border-border bg-muted/40 shadow-inner"
          :class="
            imageLoaded && !isUploading
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
            v-if="sourceImageUrl"
            ref="cropImageRef"
            :src="sourceImageUrl"
            :alt="user.name"
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
              class="size-6 animate-spin text-muted-foreground"
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

        <Card class="gap-0 bg-card/60 py-0 shadow-xs">
          <CardContent class="space-y-3 p-3">
          <div class="flex items-center justify-between gap-3">
            <Label for="avatar-crop-zoom">
              {{ t('avatar.crop.zoom') }}
            </Label>
            <span
              class="rounded-md border bg-background px-2 py-0.5 text-xs font-medium text-muted-foreground"
            >
              {{ zoomPercent }}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <Button
              type="button"
              variant="outline"
              size="icon"
              class="size-8"
              :disabled="!imageLoaded || isUploading"
              @click.stop="stepZoom(-1)"
            >
              <Minus class="size-4" />
              <span class="sr-only">{{
                t('avatar.crop.zoomOut')
              }}</span>
            </Button>
            <Slider
              id="avatar-crop-zoom"
              v-model="zoomValue"
              class="flex-1"
              :min="MIN_ZOOM"
              :max="MAX_ZOOM"
              :step="0.01"
              :disabled="!imageLoaded || isUploading"
              :aria-label="t('avatar.crop.zoom')"
            />
            <Button
              type="button"
              variant="outline"
              size="icon"
              class="size-8"
              :disabled="!imageLoaded || isUploading"
              @click.stop="stepZoom(1)"
            >
              <Plus class="size-4" />
              <span class="sr-only">{{
                t('avatar.crop.zoomIn')
              }}</span>
            </Button>
          </div>
          <div class="flex justify-end">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              :disabled="!imageLoaded || isUploading"
              @click="resetCropTransform"
            >
              <RotateCcw class="size-4" />
              {{ t('avatar.crop.reset') }}
            </Button>
          </div>
          </CardContent>
        </Card>
      </div>

      <DialogFooter>
        <Button
          type="button"
          variant="outline"
          :disabled="isUploading"
          @click="closeCropDialog"
        >
          {{ t('common.cancel') }}
        </Button>
        <Button
          type="button"
          :disabled="!imageLoaded || isUploading"
          @click="applyCrop"
        >
          <Loader2
            v-if="isUploading"
            class="size-4 animate-spin"
          />
          {{ t('avatar.crop.apply') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
