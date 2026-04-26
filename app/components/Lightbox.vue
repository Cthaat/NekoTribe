<script setup lang="ts">
import { ref, watch, computed } from 'vue';
// 1. 【核心修复】从 'radix-vue' 导入正确的、原子化的组件
import {
  DialogRoot, // 这是控制所有对话框状态的根组件
  DialogContent,
  DialogOverlay,
  DialogPortal
} from 'radix-vue';
import { Button } from '@/components/ui/button';
import {
  ChevronLeft,
  ChevronRight,
  X
} from 'lucide-vue-next';

interface MediaItem {
  type: 'image' | 'video';
  originalUrl: string;
  thumbnailUrl: string;
}

const props = defineProps<{
  items: MediaItem[];
  startIndex?: number;
  open: boolean;
}>();

const emit = defineEmits(['update:open']);

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

function next() {
  currentIndex.value =
    (currentIndex.value + 1) % props.items.length;
}

function prev() {
  currentIndex.value =
    (currentIndex.value - 1 + props.items.length) %
    props.items.length;
}
</script>

<template>
  <!-- 
    2. 【核心修复】使用 <DialogRoot> 作为最外层的控制器
       并将 v-model:open (或者 :open 和 @update:open) 绑定到它上面
  -->
  <DialogRoot
    :open="props.open"
    @update:open="value => emit('update:open', value)"
  >
    <DialogPortal>
      <DialogOverlay
        class="fixed inset-0 bg-black/80 z-50 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
      />
      <DialogContent
        class="fixed inset-0 z-50 flex items-center justify-center p-4 outline-none data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
        @escape-key-down.prevent
        @pointer-down-outside.prevent
      >
        <div
          class="relative w-full h-full flex items-center justify-center"
        >
          <div class="max-w-[90vw] max-h-[90vh] relative">
            <Transition name="fade" mode="out-in">
              <img
                v-if="currentItem.type === 'image'"
                :key="`image-${currentItem.originalUrl}`"
                :src="currentItem.originalUrl"
                class="block max-w-full max-h-full object-contain rounded-lg"
                alt="高清媒体"
              />
              <video
                v-else-if="currentItem.type === 'video'"
                :key="`video-${currentItem.originalUrl}`"
                :src="currentItem.originalUrl"
                class="block max-w-full max-h-full object-contain rounded-lg"
                controls
                autoplay
                loop
              />
            </Transition>
          </div>

          <!-- 关闭按钮 (右上角) -->
          <Button
            variant="ghost"
            size="icon"
            class="absolute top-4 right-4 h-10 w-10 rounded-full bg-black/50 text-white hover:bg-black/70"
            @click="emit('update:open', false)"
          >
            <X class="h-6 w-6" />
          </Button>

          <!-- 上一个/下一个 按钮 -->
          <template v-if="items.length > 1">
            <Button
              variant="ghost"
              size="icon"
              class="absolute left-4 ..."
              @click="prev"
            >
              <ChevronLeft class="h-8 w-8" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              class="absolute right-4 ..."
              @click="next"
            >
              <ChevronRight class="h-8 w-8" />
            </Button>
          </template>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
