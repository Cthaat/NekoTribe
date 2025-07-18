<script setup>
// 1. 【修复】确保导入了所有需要的函数
import { ref, watch, computed } from 'vue';
import TweetList from '@/components/TweetList.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue'; // 确保你已经创建了这个骨架组件
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';
import { useApiFetch } from '@/composables/useApiFetch';
import { apiFetch } from '@/composables/useApi';
import { toast } from 'vue-sonner';
import { useRoute } from 'vue-router';
import { useRequestHeaders } from '#app'; // 确保导入

const route = useRoute();
const page = ref(1);
const pageSize = ref(15);

// 2. 【修复】使用正确的 ref() 语法
const fullTweets = ref([]);
const detailsPending = ref(false);
const detailsError = ref(null); // 为详情获取创建一个专门的 error ref

// 3. 【修复】变量名保持一致
const {
  data: listApiResponse,
  pending: listPending,
  error: listError
} = useApiFetch('/api/v1/tweets/list', {
  query: {
    type: route.params.type || 'home',
    page: page,
    pageSize: pageSize
  },
  watch: [page, () => route.params.type]
});

watch(
  listApiResponse,
  async newListApiResponse => {
    if (listError.value) {
      fullTweets.value = [];
      return;
    }
    if (!newListApiResponse?.data?.tweets) {
      // 4. 【修复】使用 .value 来修改 ref
      fullTweets.value = [];
      return;
    }

    try {
      detailsPending.value = true;
      detailsError.value = null;
      fullTweets.value = []; // 清空旧数据

      const basicTweets = newListApiResponse.data.tweets;

      const detailPromises = basicTweets.map(basicTweet => {
        return apiFetch(
          `/api/v1/tweets/${basicTweet.tweetId}`
        );
      });

      const detailResponses =
        await Promise.all(detailPromises);

      // 5. 【修复】使用 .value 来赋值
      fullTweets.value = detailResponses.map(
        response => response.data.tweet
      );
    } catch (err) {
      console.error('Error fetching tweet details:', err);
      detailsError.value = err;
      if (process.client) {
        toast.error(
          '加载推文详情失败，部分内容可能无法显示。'
        );
      }
    } finally {
      detailsPending.value = false;
    }
  },
  { immediate: true }
);

const isLoading = computed(
  () => listPending.value || detailsPending.value
);
const hasError = computed(
  () => !!listError.value || !!detailsError.value
);

// 6. 【修复】totalCount 依赖正确的变量
const totalCount = computed(
  () => listApiResponse.value?.data?.totalCount || 0
);
</script>

<template>
  <div class="pt-2">
    <div class="bg-background p-10">
      <div v-if="isLoading" class="space-y-4">
        <TweetCardSkeleton
          v-for="i in 5"
          :key="`skeleton-${i}`"
        />
      </div>

      <!-- 8. 【修复】模板使用正确的错误状态变量 -->
      <div
        v-else-if="hasError"
        class="text-center text-destructive"
      >
        抱歉，加载推文时遇到问题，请刷新页面。
        <pre class="text-xs mt-2" v-if="listError">{{
          listError.message
        }}</pre>
        <pre class="text-xs mt-2" v-if="detailsError">{{
          detailsError.message
        }}</pre>
      </div>

      <!-- 9. 【修复】模板使用最终处理好的 fullTweets 数组 -->
      <TweetList
        v-else-if="fullTweets.length > 0"
        :tweets="fullTweets"
      />

      <div
        v-else
        class="text-center text-muted-foreground py-10"
      >
        这里还没有推文哦。
      </div>
    </div>

    <Pagination
      v-if="!listPending && !listError && totalCount > 0"
      v-model:page="page"
      :items-per-page="pageSize"
      :total="totalCount"
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
