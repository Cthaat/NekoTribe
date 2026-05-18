<script setup lang="ts">
import { ref, watch } from 'vue';
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
import { v2UploadMedia } from '@/services';
import type { CreateGroupData } from '@/types/groups';
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
  category: ''
});
const avatarInputRef = ref<HTMLInputElement | null>(null);
const coverInputRef = ref<HTMLInputElement | null>(null);
const isAvatarUploading = ref(false);
const isCoverUploading = ref(false);

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
        category: ''
      };
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
  formData.value.category = value ? String(value) : '';
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
  if (isAvatarUploading.value) return;
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

const handleAvatarSelected = async (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  resetAvatarInput();

  if (!file) return;

  if (!isValidImageFile(file, 5)) return;

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
};

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

  emit('create', { ...formData.value });
  emit('update:open', false);
};

const closeDialog = () => {
  emit('update:open', false);
};
</script>

<template>
  <Dialog :open="open" @update:open="closeDialog">
    <DialogContent class="max-w-lg">
      <DialogHeader>
        <DialogTitle>{{ t('groups.create.title') }}</DialogTitle>
        <DialogDescription>
          {{ t('groups.create.description') }}
        </DialogDescription>
      </DialogHeader>

      <div class="space-y-6 py-4">
        <!-- 头像上传 -->
        <div class="flex flex-col gap-4 sm:flex-row sm:items-center">
          <div class="relative">
            <input
              ref="avatarInputRef"
              type="file"
              accept="image/png,image/jpeg,image/gif,image/webp"
              class="hidden"
              @change="handleAvatarSelected"
            >
            <Avatar class="h-20 w-20">
              <AvatarImage
                v-if="formData.avatar"
                :src="formData.avatar"
              />
              <AvatarFallback class="text-2xl">
                {{ formData.name.charAt(0) || '?' }}
              </AvatarFallback>
            </Avatar>
            <Button
              type="button"
              variant="secondary"
              size="icon"
              class="absolute -bottom-1 -right-1 h-8 w-8 rounded-full"
              :disabled="isAvatarUploading"
              :aria-label="t('groups.create.avatar')"
              @click="triggerAvatarUpload"
            >
              <Loader2
                v-if="isAvatarUploading"
                class="h-4 w-4 animate-spin"
              />
              <Camera v-else class="h-4 w-4" />
            </Button>
            <Button
              v-if="formData.avatar"
              type="button"
              variant="outline"
              size="icon"
              class="absolute -right-2 -top-2 h-6 w-6 rounded-full bg-background"
              :disabled="isAvatarUploading"
              :aria-label="t('common.cancel')"
              @click="clearAvatar"
            >
              <X class="h-3 w-3" />
            </Button>
          </div>
          <div class="flex-1">
            <Label>{{ t('groups.create.avatar') }}</Label>
            <p class="text-sm text-muted-foreground">
              {{ t('groups.create.avatarDescription') }}
            </p>
          </div>
        </div>

        <!-- 封面上传 -->
        <div class="space-y-2">
          <div class="flex items-center justify-between gap-3">
            <div>
              <Label>{{ t('groups.create.cover') }}</Label>
              <p class="text-sm text-muted-foreground">
                {{ t('groups.create.coverDescription') }}
              </p>
            </div>
            <div class="flex shrink-0 gap-2">
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
                :disabled="isCoverUploading"
                :aria-label="t('groups.create.cover')"
                @click="triggerCoverUpload"
              >
                <Loader2
                  v-if="isCoverUploading"
                  class="h-4 w-4 animate-spin"
                />
                <ImagePlus v-else class="h-4 w-4" />
              </Button>
              <Button
                v-if="formData.coverImage"
                type="button"
                variant="outline"
                size="icon"
                :disabled="isCoverUploading"
                :aria-label="t('common.cancel')"
                @click="clearCover"
              >
                <X class="h-4 w-4" />
              </Button>
            </div>
          </div>
          <div
            class="relative h-28 overflow-hidden rounded-lg border bg-muted/40"
          >
            <img
              v-if="formData.coverImage"
              :src="formData.coverImage"
              :alt="formData.name || t('groups.create.cover')"
              class="h-full w-full object-cover"
            >
            <div
              v-else
              class="flex h-full items-center justify-center text-muted-foreground"
            >
              <ImagePlus class="h-6 w-6" />
            </div>
          </div>
        </div>

        <!-- 群组名称 -->
        <div class="space-y-2">
          <Label for="name">{{ t('groups.create.name') }}</Label>
          <Input
            id="name"
            v-model="formData.name"
            :placeholder="t('groups.create.namePlaceholder')"
            maxlength="50"
          />
          <p
            class="text-xs text-muted-foreground text-right"
          >
            {{ formData.name.length }}/50
          </p>
        </div>

        <!-- 群组描述 -->
        <div class="space-y-2">
          <Label for="description">{{ t('groups.create.groupDescriptionLabel') }}</Label>
          <Textarea
            id="description"
            v-model="formData.description"
            :placeholder="t('groups.create.groupDescriptionPlaceholder')"
            rows="3"
            maxlength="500"
          />
          <p
            class="text-xs text-muted-foreground text-right"
          >
            {{ formData.description.length }}/500
          </p>
        </div>

        <!-- 群组分类 -->
        <div class="space-y-2">
          <Label>{{ t('groups.create.category') }}</Label>
          <Select
            :model-value="formData.category"
            @update:model-value="updateCategory"
          >
            <SelectTrigger>
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

        <!-- 隐私设置 -->
        <div class="space-y-3">
          <Label>{{ t('groups.create.privacySettings') }}</Label>
          <RadioGroup
            v-model="formData.privacy"
            class="space-y-2"
          >
            <div
              v-for="option in privacyOptions"
              :key="option.value"
              class="flex items-start gap-3 p-3 rounded-lg border cursor-pointer hover:bg-muted/50 transition-colors"
              :class="{
                'border-primary bg-primary/5':
                  formData.privacy === option.value
              }"
              @click="formData.privacy = option.value"
            >
              <RadioGroupItem
                :value="option.value"
                :id="option.value"
                class="mt-0.5"
              />
              <div class="flex-1">
                <div class="flex items-center gap-2">
                  <component
                    :is="option.icon"
                    class="h-4 w-4"
                  />
                  <span class="font-medium text-sm">{{
                    t(option.labelKey)
                  }}</span>
                </div>
                <p
                  class="text-xs text-muted-foreground mt-0.5"
                >
                  {{ t(option.descriptionKey) }}
                </p>
              </div>
            </div>
          </RadioGroup>
        </div>
      </div>

      <DialogFooter>
        <Button class="w-full sm:w-auto" variant="outline" @click="closeDialog">
          {{ t('common.cancel') }}
        </Button>
        <Button class="w-full sm:w-auto" @click="handleSubmit">
          {{ t('groups.actions.create') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
