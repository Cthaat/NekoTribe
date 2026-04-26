<script setup lang="ts">
import { ref, computed, type PropType } from 'vue';
import { toast } from 'vue-sonner';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Loader2 } from 'lucide-vue-next';
import { apiFetch } from '@/composables/useApi';
import { usePreferenceStore } from '~/stores/user'; // 导入 store

// --- Props & Emits ---
const props = defineProps({
  user: {
    type: Object as PropType<{
      name: string;
      avatar: string;
    }>,
    required: true
  },
  // 上传的目标 API 端点
  uploadUrl: {
    type: String,
    default: '/api/v1/users/avatar-upload' // 提供一个默认值
  }
});

const emit = defineEmits(['update:avatar']);

// --- Refs for State Management ---
const fileInputRef = ref<HTMLInputElement | null>(null);
const isUploading = ref(false);
const previewUrl = ref<string | null>(null);

// --- Computed Property for Display ---
// 优先显示本地预览的 URL，否则显示来自 props 的头像 URL
const displayAvatarUrl = computed(() => {
  return previewUrl.value || props.user.avatar;
});

// --- Methods ---

// 触发隐藏的文件输入框
const triggerFileUpload = () => {
  if (isUploading.value) return; // 如果正在上传，则阻止再次点击
  fileInputRef.value?.click();
};

// 当用户选择文件后触发
const onFileSelected = (event: Event) => {
  const target = event.target as HTMLInputElement;
  const file = target.files?.[0];

  if (!file) {
    return;
  }

  // 文件验证（大小和类型）
  const maxSizeInMB = 5;
  if (file.size > maxSizeInMB * 1024 * 1024) {
    toast.error(`文件大小不能超过 ${maxSizeInMB}MB`);
    return;
  }

  // 创建本地预览 URL
  previewUrl.value = URL.createObjectURL(file);

  // 开始上传
  uploadAvatar(file);
};

// 执行上传操作
const uploadAvatar = async (file: File) => {
  isUploading.value = true;

  // FormData 是专门用于发送文件和其他表单数据的对象
  const formData = new FormData();
  formData.append('avatar', file); // 'avatar' 这个键名需要和后端约定好

  try {
    // 发起 API 请求
    const response = (await apiFetch(
      '/api/v1/users/me/avatar',
      {
        method: 'POST',
        body: formData
        // 注意：使用 FormData 时，通常不需要手动设置 'Content-Type' 头
        // 浏览器会自动设置为 'multipart/form-data' 并包含正确的 boundary
      }
    )) as { data?: { url: string } };

    if (response.data?.url) {
      // 上传成功，通知父组件更新头像
      emit('update:avatar', response.data.url);
      const preferenceStore = usePreferenceStore();
      // 更新 store 中的用户头像
      preferenceStore.updatePreference('user', {
        ...preferenceStore.preferences.user,
        avatarUrl: response.data.url
      });
      // 刷新页面
      window.location.reload();
      toast('头像更新成功！');
    } else {
      throw new Error(
        'API did not return a new avatar URL.'
      );
    }
  } catch (error) {
    console.error('上传头像失败:', error);
    toast.error('上传失败，请重试。');
    // 上传失败，清除本地预览，恢复到旧头像
    previewUrl.value = null;
  } finally {
    isUploading.value = false;
    // 清除 input 的值，确保下次选择相同文件也能触发 change 事件
    if (fileInputRef.value) {
      fileInputRef.value.value = '';
    }
  }
};
</script>

<template>
  <div
    class="relative cursor-pointer"
    @click="triggerFileUpload"
  >
    <!-- 
      使用一个 div 作为容器，并设置相对定位，
      以便我们可以在它上面覆盖一个加载指示器。
    -->
    <Avatar class="w-24 h-24 border">
      <AvatarImage
        :src="displayAvatarUrl"
        :alt="user.name"
      />
      <AvatarFallback>{{
        user.name?.slice(0, 2).toUpperCase()
      }}</AvatarFallback>
    </Avatar>

    <!-- 加载状态遮罩层 -->
    <div
      v-if="isUploading"
      class="absolute inset-0 flex items-center justify-center bg-black bg-opacity-50 rounded-full"
    >
      <Loader2 class="size-8 text-white animate-spin" />
    </div>

    <!-- 
      隐藏的文件输入框。我们通过 JS 来触发它的点击事件。
      - `ref`: 让我们可以在 script 中引用这个元素。
      - `accept`: 限制用户只能选择图片文件。
      - `@change`: 当用户选择了文件后，触发 onFileSelected 方法。
    -->
    <input
      ref="fileInputRef"
      type="file"
      class="hidden"
      accept="image/png, image/jpeg, image/gif"
      @change="onFileSelected"
    />
  </div>
</template>
