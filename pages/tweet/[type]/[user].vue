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
const totalCount = ref(0); // 总条数

const {
  data: tweets,
  pending,
  error
} = await useApiFetch('/api/v1/tweets/list', {
  query: {
    type: route.params.type || 'home',
    page: page.value,
    pageSize: pageSize.value
  }
});

// `await` 之后，数据已经获取完毕（或已出错）
// 现在可以安全地检查错误或使用数据了
if (error.value) {
  toast.error('加载推文失败，请稍后再试。');
  console.error('Error fetching tweets:', error.value);
} else {
  totalCount.value = tweets.value.data.totalCount || 0;
  // 在这里，tweets.value 就包含了你的数据
  console.log(
    'Tweets fetched successfully',
    tweets.value.data.tweets[0],
    'Total count:',
    totalCount.value
  );
}
</script>

<template>
  <!-- 根容器 -->
  <div>
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
        抱歉，加载推文时遇到问题，请刷新页面。
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
      :items-per-page="pageSize"
      :total="totalCount"
      :default-page="1"
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
