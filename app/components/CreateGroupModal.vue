<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';
import {
  Camera,
  Globe,
  ImagePlus,
  Loader2,
  Lock,
  Shield,
  X
} from 'lucide-vue-next';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import {
  RadioGroup,
  RadioGroupItem
} from '@/components/ui/radio-group';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { toast } from 'vue-sonner';
import GroupAvatarCropDialog from './GroupAvatarCropDialog.vue';
import { v2UploadMedia } from '@/services';
import type {
  CreateGroupData,
  GroupCategory
} from '@/types/groups';
import { normalizeAssetUrl } from '@/utils/assets';

export type { CreateGroupData } from '@/types/groups';
const { t } = useAppLocale();

const props = defineProps<{
  open: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'create', data: CreateGroupData): void;
}>();

// 表单数据
const formData = ref<CreateGroupData>({
  name: '',
  description: '',
  avatar: '',
  coverImage: '',
  privacy: 'public',
  category: 'tech',
  tags: []
});
const tagsText = ref('');
const avatarInputRef = ref<HTMLInputElement | null>(null);
const coverInputRef = ref<HTMLInputElement | null>(null);
const isAvatarUploading = ref(false);
const isCoverUploading = ref(false);
const avatarCropDialogOpen = ref(false);
const avatarCropSourceUrl = ref<string | null>(null);
const avatarCropFileName = ref('avatar.jpg');

// 重置表单
watch(
  () => props.open,
  isOpen => {
    if (!isOpen) {
      formData.value = {
        name: '',
        description: '',
        avatar: '',
        coverImage: '',
        privacy: 'public',
        category: 'tech',
        tags: []
      };
      tagsText.value = '';
      isAvatarUploading.value = false;
      isCoverUploading.value = false;
      resetAvatarInput();
      resetCoverInput();
      closeAvatarCropDialog();
    }
  }
);

// 分类选项
const categoryOptions = [
  { value: 'tech', labelKey: 'groups.filters.category.tech' },
  { value: 'game', labelKey: 'groups.filters.category.game' },
  { value: 'music', labelKey: 'groups.filters.category.music' },
  { value: 'art', labelKey: 'groups.filters.category.art' },
  { value: 'life', labelKey: 'groups.filters.category.life' },
  { value: 'study', labelKey: 'groups.filters.category.study' },
  { value: 'work', labelKey: 'groups.filters.category.work' },
  { value: 'other', labelKey: 'groups.filters.category.other' }
];

function normalizeTags(value: string): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of value.split(/[,，\s]+/)) {
    const tag = raw.replace(/^#/, '').trim().slice(0, 50);
    const key = tag.toLowerCase();
    if (!tag || seen.has(key)) continue;
    seen.add(key);
    result.push(tag);
    if (result.length >= 8) break;
  }
  return result;
}

// 隐私选项
const privacyOptions = [
  {
    value: 'public' as const,
    labelKey: 'groups.filters.privacy.public',
    descriptionKey: 'groups.create.privacy.publicDescription',
    icon: Globe
  },
  {
    value: 'private' as const,
    labelKey: 'groups.filters.privacy.private',
    descriptionKey: 'groups.create.privacy.privateDescription',
    icon: Lock
  },
  {
    value: 'secret' as const,
    labelKey: 'groups.filters.privacy.secret',
    descriptionKey: 'groups.create.privacy.secretDescription',
    icon: Shield
  }
];

// 更新分类
const updateCategory = (value: unknown) => {
  const next = String(value);
  if (
    categoryOptions.some(option => option.value === next)
  ) {
    formData.value.category = next as GroupCategory;
  }
};

const resetAvatarInput = () => {
  if (avatarInputRef.value) {
    avatarInputRef.value.value = '';
  }
};

const resetCoverInput = () => {
  if (coverInputRef.value) {
    coverInputRef.value.value = '';
  }
};

const triggerAvatarUpload = () => {
  if (isAvatarUploading.value || avatarCropDialogOpen.value) return;
  avatarInputRef.value?.click();
};

const triggerCoverUpload = () => {
  if (isCoverUploading.value) return;
  coverInputRef.value?.click();
};

const clearAvatar = () => {
  if (isAvatarUploading.value) return;
  formData.value.avatar = '';
  resetAvatarInput();
};

const clearCover = () => {
  if (isCoverUploading.value) return;
  formData.value.coverImage = '';
  resetCoverInput();
};

function isValidImageFile(file: File, maxSizeInMB: number): boolean {
  if (!file.type.startsWith('image/')) {
    toast.error(t('avatar.validation.imageOnly'));
    return false;
  }

  if (file.size > maxSizeInMB * 1024 * 1024) {
    toast.error(
      t('avatar.validation.maxSize', { size: maxSizeInMB })
    );
    return false;
  }

  return true;
}

async function uploadGroupImage(
  file: File,
  altText: string
): Promise<string> {
  const body = new FormData();
  body.append('file', file);
  body.append('alt_text', altText || file.name);
  const media = await v2UploadMedia(body);
  return normalizeAssetUrl(media.public_url);
}

function revokeObjectUrl(url: string | null): void {
  if (url) {
    URL.revokeObjectURL(url);
  }
}

function closeAvatarCropDialog(): void {
  avatarCropDialogOpen.value = false;
  revokeObjectUrl(avatarCropSourceUrl.value);
  avatarCropSourceUrl.value = null;
}

function openAvatarCropDialog(file: File): void {
  closeAvatarCropDialog();
  avatarCropFileName.value = file.name || 'avatar.jpg';
  avatarCropSourceUrl.value = URL.createObjectURL(file);
  avatarCropDialogOpen.value = true;
}

const handleAvatarSelected = async (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  resetAvatarInput();

  if (!file) return;

  if (!isValidImageFile(file, 5)) return;

  openAvatarCropDialog(file);
};

async function handleAvatarCropApply(file: File): Promise<void> {
  closeAvatarCropDialog();
  isAvatarUploading.value = true;
  try {
    if (props.open) {
      formData.value.avatar = await uploadGroupImage(
        file,
        formData.value.name || file.name
      );
    }
  } catch (error) {
    toast.error(t('avatar.feedback.uploadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    isAvatarUploading.value = false;
  }
}

const handleCoverSelected = async (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  resetCoverInput();

  if (!file) return;

  if (!isValidImageFile(file, 8)) return;

  isCoverUploading.value = true;
  try {
    if (props.open) {
      formData.value.coverImage = await uploadGroupImage(
        file,
        formData.value.name || file.name
      );
    }
  } catch (error) {
    toast.error(t('avatar.feedback.uploadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    isCoverUploading.value = false;
  }
};

// 提交表单
const handleSubmit = () => {
  if (!formData.value.name.trim()) {
    toast.error(t('groups.create.validation.nameRequired'));
    return;
  }
  if (!formData.value.description.trim()) {
    toast.error(t('groups.create.validation.descriptionRequired'));
    return;
  }
  if (!formData.value.category) {
    toast.error(t('groups.create.validation.categoryRequired'));
    return;
  }

  emit('create', {
    ...formData.value,
    tags: normalizeTags(tagsText.value)
  });
  emit('update:open', false);
};

const closeDialog = () => {
  emit('update:open', false);
};

onBeforeUnmount(() => {
  closeAvatarCropDialog();
});
</script>

<template>
  <Dialog :open="open" @update:open="closeDialog">
    <DialogContent class="max-w-lg sm:max-h-[90vh] sm:overflow-y-auto">
      <DialogHeader>
        <DialogTitle>{{ t('groups.create.title') }}</DialogTitle>
        <DialogDescription>
          {{ t('groups.create.description') }}
        </DialogDescription>
      </DialogHeader>

      <div class="space-y-5 py-2">
        <div class="flex items-center gap-4">
          <div class="relative">
            <input
              ref="avatarInputRef"
              type="file"
              accept="image/png,image/jpeg,image/gif,image/webp"
              class="hidden"
              @change="handleAvatarSelected"
            >
            <Avatar class="h-20 w-20 rounded-xl ring-1 ring-border">
              <AvatarImage
                v-if="formData.avatar"
                :src="formData.avatar"
                class="rounded-xl"
              />
              <AvatarFallback class="rounded-xl bg-muted text-2xl font-semibold">
                {{ formData.name.charAt(0) || '?' }}
              </AvatarFallback>
            </Avatar>
            <Button
              type="button"
              variant="secondary"
              size="icon"
              class="absolute -bottom-1 -right-1 h-7 w-7 rounded-full border border-border shadow-sm"
              :disabled="isAvatarUploading"
              :aria-label="t('groups.create.avatar')"
              @click="triggerAvatarUpload"
            >
              <Loader2
                v-if="isAvatarUploading"
                class="h-3.5 w-3.5 animate-spin"
              />
              <Camera v-else class="h-3.5 w-3.5" />
            </Button>
            <button
              v-if="formData.avatar"
              type="button"
              class="absolute -right-2 -top-2 flex h-5 w-5 items-center justify-center rounded-full border border-border bg-background text-muted-foreground shadow-sm transition-colors hover:bg-muted hover:text-foreground"
              :disabled="isAvatarUploading"
              :aria-label="t('common.cancel')"
              @click="clearAvatar"
            >
              <X class="h-3 w-3" />
            </button>
          </div>
          <div class="flex-1">
            <Label class="text-sm font-medium">
              {{ t('groups.create.avatar') }}
            </Label>
            <p class="mt-1 text-xs text-muted-foreground">
              {{ t('groups.create.avatarDescription') }}
            </p>
          </div>
        </div>

        <div class="space-y-2">
          <div class="flex items-center justify-between gap-3">
            <div>
              <Label class="text-sm font-medium">
                {{ t('groups.create.cover') }}
              </Label>
              <p class="mt-1 text-xs text-muted-foreground">
                {{ t('groups.create.coverDescription') }}
              </p>
            </div>
            <div class="flex shrink-0 gap-1.5">
              <input
                ref="coverInputRef"
                type="file"
                accept="image/png,image/jpeg,image/gif,image/webp"
                class="hidden"
                @change="handleCoverSelected"
              >
              <Button
                type="button"
                variant="outline"
                size="icon"
                class="h-8 w-8"
                :disabled="isCoverUploading"
                :aria-label="t('groups.create.cover')"
                @click="triggerCoverUpload"
              >
                <Loader2
                  v-if="isCoverUploading"
                  class="h-3.5 w-3.5 animate-spin"
                />
                <ImagePlus v-else class="h-3.5 w-3.5" />
              </Button>
              <Button
                v-if="formData.coverImage"
                type="button"
                variant="outline"
                size="icon"
                class="h-8 w-8"
                :disabled="isCoverUploading"
                :aria-label="t('common.cancel')"
                @click="clearCover"
              >
                <X class="h-3.5 w-3.5" />
              </Button>
            </div>
          </div>
          <div
            class="relative h-28 overflow-hidden rounded-lg border border-border/60 bg-muted/30"
          >
            <img
              v-if="formData.coverImage"
              :src="formData.coverImage"
              :alt="formData.name || t('groups.create.cover')"
              class="h-full w-full object-cover"
            >
            <div
              v-else
              class="flex h-full flex-col items-center justify-center gap-1.5 text-muted-foreground"
            >
              <ImagePlus class="h-5 w-5" />
              <span class="text-xs">
                {{ t('groups.create.coverDescription') }}
              </span>
            </div>
          </div>
        </div>

        <div class="space-y-1.5">
          <Label for="name" class="text-sm font-medium">
            {{ t('groups.create.name') }}
          </Label>
          <Input
            id="name"
            v-model="formData.name"
            :placeholder="t('groups.create.namePlaceholder')"
            maxlength="50"
            class="h-9 shadow-xs"
          />
          <p class="text-right tabular-nums text-xs text-muted-foreground">
            {{ formData.name.length }} / 50
          </p>
        </div>

        <div class="space-y-1.5">
          <Label for="description" class="text-sm font-medium">
            {{ t('groups.create.groupDescriptionLabel') }}
          </Label>
          <Textarea
            id="description"
            v-model="formData.description"
            :placeholder="t('groups.create.groupDescriptionPlaceholder')"
            rows="3"
            maxlength="500"
            class="min-h-20 resize-none shadow-xs"
          />
          <p class="text-right tabular-nums text-xs text-muted-foreground">
            {{ formData.description.length }} / 500
          </p>
        </div>

        <div class="space-y-1.5">
          <Label class="text-sm font-medium">
            {{ t('groups.create.category') }}
          </Label>
          <Select
            :model-value="formData.category"
            @update:model-value="updateCategory"
          >
            <SelectTrigger class="h-9">
              <SelectValue :placeholder="t('groups.create.categoryPlaceholder')" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem
                v-for="option in categoryOptions"
                :key="option.value"
                :value="option.value"
              >
                {{ t(option.labelKey) }}
              </SelectItem>
            </SelectContent>
          </Select>
        </div>

        <div class="space-y-1.5">
          <Label for="group-tags" class="text-sm font-medium">
            {{ t('groups.create.tags') }}
          </Label>
          <Input
            id="group-tags"
            v-model="tagsText"
            :placeholder="t('groups.create.tagsPlaceholder')"
            maxlength="160"
            class="h-9 shadow-xs"
          />
          <p class="text-xs text-muted-foreground">
            {{ t('groups.create.tagsHint') }}
          </p>
        </div>

        <div class="space-y-2">
          <Label class="text-sm font-medium">
            {{ t('groups.create.privacySettings') }}
          </Label>
          <RadioGroup
            v-model="formData.privacy"
            class="space-y-2"
          >
            <label
              v-for="option in privacyOptions"
              :key="option.value"
              :for="option.value"
              class="flex cursor-pointer items-start gap-3 rounded-lg border border-border/60 p-3 transition-colors hover:bg-muted/40"
              :class="{
                'border-ring/60 bg-primary/[0.03] ring-2 ring-ring/20':
                  formData.privacy === option.value
              }"
            >
              <RadioGroupItem
                :value="option.value"
                :id="option.value"
                class="mt-0.5"
              />
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <component
                    :is="option.icon"
                    class="h-3.5 w-3.5 text-muted-foreground"
                  />
                  <span class="text-sm font-medium">
                    {{ t(option.labelKey) }}
                  </span>
                </div>
                <p class="mt-0.5 text-xs leading-relaxed text-muted-foreground">
                  {{ t(option.descriptionKey) }}
                </p>
              </div>
            </label>
          </RadioGroup>
        </div>
      </div>

      <DialogFooter class="gap-2 sm:gap-0">
        <Button
          class="w-full sm:w-auto"
          variant="outline"
          @click="closeDialog"
        >
          {{ t('common.cancel') }}
        </Button>
        <Button
          class="w-full sm:w-auto"
          :disabled="isAvatarUploading || isCoverUploading"
          @click="handleSubmit"
        >
          {{ t('groups.actions.create') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>

  <GroupAvatarCropDialog
    v-model:open="avatarCropDialogOpen"
    :source-url="avatarCropSourceUrl"
    :file-name="avatarCropFileName"
    :alt="formData.name || t('groups.create.avatar')"
    @update:open="
      value => {
        if (!value) closeAvatarCropDialog()
      }
    "
    @apply="handleAvatarCropApply"
  />
</template>
