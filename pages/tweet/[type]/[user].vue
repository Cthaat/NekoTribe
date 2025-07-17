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

const preferenceStore = usePreferenceStore();
const route = useRoute();

const page = ref(1); // 当前页码
const pageSize = ref(15); // 每页条数

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
  // 在这里，tweets.value 就包含了你的数据
  console.log(
    'Tweets fetched successfully',
    tweets.value.data.tweets
  );
}
</script>

<template>
  <div class="bg-background p-10">
    <TweetList />
  </div>
  <Pagination
    v-slot="{ page }"
    :items-per-page="10"
    :total="300"
    :default-page="1"
  >
    <PaginationContent v-slot="{ items }">
      <PaginationPrevious />

      <template v-for="(item, index) in items" :key="index">
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
</template>
