<script setup>
import TweetList from '@/components/TweetList.vue';
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';
import { apiFetch } from '@/composables/useApi';
import { useApiFetch } from '@/composables/useApiFetch'; // 导入自定义的 useApiFetch 组合式 API
import { toast } from 'vue-sonner';
import { useRoute } from 'vue-router'; // 或者依赖 Nuxt 的自动导入
import { Skeleton } from '@/components/ui/skeleton';

const preferenceStore = usePreferenceStore();
const route = useRoute();

const page = ref(1); // 当前页码
const pageSize = ref(15); // 每页条数

const {
  data: tweets,
  pending,
  error
} = useApiFetch('/api/v1/tweets/list', {
  query: {
    type: route.params.type || 'home',
    page: page,
    pageSize: pageSize
  },
  watch: [page]
});

const totalCount = computed(
  () => tweets.value?.data?.totalCount || 0
);

// 【修复 3】使用 watch 来处理副作用，比如错误提示
// 这个 watcher 只会在 error.value 从无到有时才触发
watch(error, newError => {
  if (newError) {
    // 确保只在客户端显示 toast，避免 SSR 错误
    if (process.client) {
      toast.error('加载推文失败，请稍后再试。');
    }
    console.error('Error fetching tweets:', newError);
  }
});

// (可选) 如果你需要在数据到达时打印日志，也可以用 watch
watch(tweets, newTweets => {
  if (newTweets) {
    console.log('Tweets data arrived:', newTweets.data);
  }
});
</script>

<template>
  <!-- 根容器 -->
  <div class="pt-2">
    <!-- 主内容区域 -->
    <div class="bg-background p-10">
      <!-- 1. 加载状态：当 pending 为 true 时，显示骨架屏 -->
      <div v-if="pending">
        <div class="space-y-4">
          <div
            v-for="i in 5"
            :key="i"
            class="flex items-start space-x-4 rounded-md border p-4"
          >
            <Skeleton class="size-12 rounded-full" />
            <div class="flex-1 space-y-2">
              <Skeleton class="h-4 w-1/4" />
              <Skeleton class="h-4 w-full" />
            </div>
          </div>
        </div>
      </div>

      <!-- 2. 错误状态：当 error 有值时，显示错误信息 -->
      <div
        v-else-if="error"
        class="text-center text-destructive"
      >
        抱歉，加载推文时遇到问题，请刷新页面。 {{ error }}
      </div>

      <!-- 3. 成功状态：当加载完成且无错误时，渲染 TweetList -->
      <!--    并传递正确的推文数组！ -->
      <TweetList
        v-else-if="tweets && tweets.data"
        :tweets="tweets.data.tweets"
        class="bg-background p-10"
      />
    </div>

    <Pagination
      v-slot="{ page }"
      v-model:page="page"
      :items-per-page="pageSize"
      :total="totalCount"
      :default-page="1"
      class="mb-8 flex justify-center"
    >
      <PaginationContent v-slot="{ items }">
        <PaginationPrevious />

        <template
          v-for="(item, index) in items"
          :key="index"
        >
          <PaginationItem
            v-if="item.type === 'page'"
            :value="item.value"
            :is-active="item.value === page"
          >
            {{ item.value }}
          </PaginationItem>
        </template>
        <PaginationNext />
      </PaginationContent>
    </Pagination>
  </div>
</template>
