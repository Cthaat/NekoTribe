<script setup lang="ts">
import { ref, watch } from 'vue';
import {
  Camera,
  Globe,
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
import type { CreateGroupData } from '@/types/groups';

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
        <div class="flex items-center gap-4">
          <div class="relative">
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
              variant="secondary"
              size="icon"
              class="absolute -bottom-1 -right-1 h-8 w-8 rounded-full"
            >
              <Camera class="h-4 w-4" />
            </Button>
          </div>
          <div class="flex-1">
            <Label>{{ t('groups.create.avatar') }}</Label>
            <p class="text-sm text-muted-foreground">
              {{ t('groups.create.avatarDescription') }}
            </p>
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
        <Button variant="outline" @click="closeDialog">
          {{ t('common.cancel') }}
        </Button>
        <Button @click="handleSubmit">
          {{ t('groups.actions.create') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
