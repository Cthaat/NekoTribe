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

export interface CreateGroupData {
  name: string;
  description: string;
  avatar: string;
  coverImage: string;
  privacy: 'public' | 'private' | 'secret';
  category: string;
}

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
  { value: 'tech', label: '科技' },
  { value: 'game', label: '游戏' },
  { value: 'music', label: '音乐' },
  { value: 'art', label: '艺术' },
  { value: 'life', label: '生活' },
  { value: 'study', label: '学习' },
  { value: 'work', label: '工作' },
  { value: 'other', label: '其他' }
];

// 隐私选项
const privacyOptions = [
  {
    value: 'public' as const,
    label: '公开群组',
    description: '任何人都可以查看和加入',
    icon: Globe
  },
  {
    value: 'private' as const,
    label: '私密群组',
    description: '需要申请或邀请才能加入',
    icon: Lock
  },
  {
    value: 'secret' as const,
    label: '隐秘群组',
    description: '仅邀请可见和加入',
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
    toast.error('请输入群组名称');
    return;
  }
  if (!formData.value.description.trim()) {
    toast.error('请输入群组描述');
    return;
  }
  if (!formData.value.category) {
    toast.error('请选择群组分类');
    return;
  }

  emit('create', { ...formData.value });
  emit('update:open', false);
  toast.success('群组创建成功！');
};

const closeDialog = () => {
  emit('update:open', false);
};
</script>

<template>
  <Dialog :open="open" @update:open="closeDialog">
    <DialogContent class="max-w-lg">
      <DialogHeader>
        <DialogTitle>创建新群组</DialogTitle>
        <DialogDescription>
          创建一个群组来聚集志同道合的朋友
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
            <Label>群组头像</Label>
            <p class="text-sm text-muted-foreground">
              点击上传群组头像
            </p>
          </div>
        </div>

        <!-- 群组名称 -->
        <div class="space-y-2">
          <Label for="name">群组名称 *</Label>
          <Input
            id="name"
            v-model="formData.name"
            placeholder="输入群组名称"
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
          <Label for="description">群组描述 *</Label>
          <Textarea
            id="description"
            v-model="formData.description"
            placeholder="描述一下你的群组..."
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
          <Label>群组分类 *</Label>
          <Select
            :model-value="formData.category"
            @update:model-value="updateCategory"
          >
            <SelectTrigger>
              <SelectValue placeholder="选择分类" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem
                v-for="option in categoryOptions"
                :key="option.value"
                :value="option.value"
              >
                {{ option.label }}
              </SelectItem>
            </SelectContent>
          </Select>
        </div>

        <!-- 隐私设置 -->
        <div class="space-y-3">
          <Label>隐私设置</Label>
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
                    option.label
                  }}</span>
                </div>
                <p
                  class="text-xs text-muted-foreground mt-0.5"
                >
                  {{ option.description }}
                </p>
              </div>
            </div>
          </RadioGroup>
        </div>
      </div>

      <DialogFooter>
        <Button variant="outline" @click="closeDialog">
          取消
        </Button>
        <Button @click="handleSubmit"> 创建群组 </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
