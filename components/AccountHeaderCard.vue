<script setup lang="ts">
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import AvatarUploader from '@/components/AvatarUploader.vue'; // 导入你的新组件
// 1. 导入所有这个组件需要的依赖项
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Progress } from '@/components/ui/progress';
import { ref } from 'vue';
import {
  ArrowUp,
  ArrowDown,
  User,
  Mail,
  MapPin,
  MoreHorizontal
} from 'lucide-vue-next';
import type { PropType } from 'vue';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '~/stores/user'; // 导入 store

const preferenceStore = usePreferenceStore();

// 2. 为 props 定义清晰的 TypeScript 类型
interface UserData {
  id: number;
  name: string;
  title: string;
  location: string;
  email: string;
  avatar: string;
  stats: {
    followersCount: number;
    followingCount: number;
    likesCount: number;
  };
  point: number;
}

interface TabItem {
  name: string;
  to: string;
}

// 3. 使用 defineProps 接收从父组件传递过来的数据
const props = defineProps({
  user: {
    type: Object as PropType<UserData>,
    required: true
  },
  accountTabs: {
    type: Array as PropType<TabItem[]>,
    required: true
  }
});

// 3.定义 emits，声明该组件会触发 'update:user' 事件
const emit = defineEmits(['update:user', 'follow']);

// 4. 处理头像更新的正确方式
const handleAvatarUpdate = (
  newAvatarRelativePath: string
) => {
  // 创建一个 props.user 的副本
  const updatedUser = { ...props.user };
  // 更新副本的 avatar 属性 (假设后端返回的是相对路径)
  // 你需要在这里拼接完整的 URL，或者确保你的 API 调用者来做这件事
  const BACKEND_URL = ''; // 示例 URL
  updatedUser.avatar = `${BACKEND_URL}${newAvatarRelativePath}`;
  // c. 通过 emit 事件将整个更新后的 user 对象发送给父组件
  emit('update:user', updatedUser);
};

// 将需要传递给 AvatarUploader 的数据包装成一个 computed 属性
//    这样可以确保当 props.user 变化时，子组件也能接收到更新
const avatarUploaderProps = computed(() => ({
  name: props.user.name,
  avatar: props.user.avatar
}));

const MAX_POSSIBLE_SCORE = 3000;

const normalizedScore = computed(() => {
  const originalScore = props.user.point;
  const minScore = 0; // 最小可能分数

  // 应用归一化公式
  let score_0_to_100 =
    ((originalScore - minScore) /
      (MAX_POSSIBLE_SCORE - minScore)) *
    100;

  // 3. 确保分数不会超过 100 或低于 0（处理边界情况）
  //    如果原始分数可能超过你设定的最大值，这一步很重要
  score_0_to_100 = Math.max(
    0,
    Math.min(score_0_to_100, 100)
  );

  return score_0_to_100;
});

const tabValue = defineModel<string>();

function followUser() {
  if (
    props.user.id ===
    preferenceStore.preferences.user.userId
  ) {
    toast.error('你不能关注自己。');
    return;
  }
  emit('follow', props.user);
}
</script>

<template>
  <!-- 整个组件的最外层是一个 Card -->
  <Card>
    <!-- a. 卡片内容区，只包含需要内边距 (p-6) 的用户信息 -->
    <CardContent class="p-6">
      <div
        class="flex flex-col sm:flex-row items-start gap-6"
      >
        <AvatarUploader
          :user="avatarUploaderProps"
          @update:avatar="handleAvatarUpdate"
          class="absolute bottom-0 right-0"
        />

        <!-- 右侧的所有信息，使用 space-y-4 来创建垂直间距 -->
        <div class="flex-1 space-y-4">
          <!-- 用户名和操作按钮 -->
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-xl font-semibold">
                {{ user.name }}
              </h2>
              <div
                class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-muted-foreground mt-1"
              >
                <span
                  class="flex items-center gap-1.5"
                  v-if="user.title"
                  ><User class="w-4 h-4" />{{
                    user.title
                  }}</span
                >
                <span class="flex items-center gap-1.5"
                  ><MapPin class="w-4 h-4" />{{
                    user.location
                  }}</span
                >
                <span
                  class="flex items-center gap-1.5"
                  v-if="user.email"
                  ><Mail class="w-4 h-4" />{{
                    user.email
                  }}</span
                >
              </div>
            </div>
            <div class="flex items-center space-x-2">
              <Button variant="outline" @click="followUser"
                >Follow</Button
              >
              <Button variant="ghost" size="icon"
                ><MoreHorizontal class="w-4 h-4"
              /></Button>
            </div>
          </div>

          <!-- 分割线 -->
          <div class="border-t"></div>

          <!-- 统计数据和进度条 -->
          <div
            class="flex flex-col sm:flex-row items-center gap-4"
          >
            <div class="flex-1 grid grid-cols-3 gap-4">
              <div class="text-center">
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  {{
                    user.stats.followersCount.toLocaleString()
                  }}
                </p>
                <p class="text-xs text-muted-foreground">
                  Followers
                </p>
              </div>
              <div class="text-center">
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  {{ user.stats.followingCount }}
                </p>
                <p class="text-xs text-muted-foreground">
                  followingCount
                </p>
              </div>
              <div class="text-center">
                <p
                  class="flex items-center justify-center gap-1 text-lg font-bold"
                >
                  {{ user.stats.likesCount }}
                </p>
                <p class="text-xs text-muted-foreground">
                  likesCount
                </p>
              </div>
            </div>
            <div class="w-full sm:w-1/3">
              <label
                for="completion"
                class="text-sm font-medium"
                >Active Score</label
              >
              <div class="flex items-center gap-2">
                <Progress
                  :model-value="normalizedScore"
                  class="w-full"
                />
                <span class="font-semibold text-sm">{{
                  user.point
                }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </CardContent>
  </Card>
  <!-- b. 选项卡导航，作为 Card 的直接子元素，以实现正确的边框样式 -->
  <div
    class="inline-flex h-10 items-center justify-center rounded-full bg-muted p-1 text-muted-foreground"
    v-if="accountTabs.length > 0"
  >
    <Tabs default-value="overview" class="w-full">
      <TabsList>
        <TabsTrigger
          v-for="tab in accountTabs"
          :value="tab.name"
          class="inline-flex items-center justify-center whitespace-nowrap rounded-full px-3 py-1.5 text-sm font-medium ring-offset-background transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          active-class="bg-background text-foreground shadow-sm"
        >
          <NuxtLink
            :key="tab.name"
            :to="tab.to"
            :onclick="() => (tabValue = tab.name)"
          >
            {{ tab.name }}
          </NuxtLink>
        </TabsTrigger>
      </TabsList>
    </Tabs>
  </div>
</template>
