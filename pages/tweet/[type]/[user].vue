<!-- TODO: 修复类型检查 -->
<script lang="ts" setup>
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
const fullTweets = ref<any[]>([]);
const detailsPending = ref(false);
const detailsError = ref<unknown>(null); // 为详情获取创建一个专门的 error ref

// 3. 【修复】变量名保持一致
interface TweetListApiResponse {
  data?: {
    tweets?: any[];
    totalCount?: number;
  };
}

const {
  data: listApiResponse,
  pending: listPending,
  error: listError
} = useApiFetch<TweetListApiResponse>(
  '/api/v1/tweets/list',
  {
    query: {
      type: route.params.type || 'home',
      page: page,
      pageSize: pageSize
    },
    watch: [page, () => route.params.type]
  }
);

// TODO: 修复后端，获取推文详情时可以同时获取点赞情况和书签情况
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
        (response: any, index: number) => ({
          ...response.data.tweet,
          isLikedByUser: basicTweets[index].isLikedByUser,
          isBookmarkedByUser:
            basicTweets[index].isBookmarkedByUser
        })
      );
    } catch (err) {
      console.error('Error fetching tweet details:', err);
      detailsError.value = err as Error;
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

// TODO: 以上为史山代码，等待重构 ---

// 6. 【修复】totalCount 依赖正确的变量
const totalCount = computed(
  () => listApiResponse.value?.data?.totalCount || 0
);

async function handleDeleteTweet(tweetId: any) {
  console.log('Deleting tweet:', tweetId);
  // 在这里调用你的API来删除推文
  const response: any = await apiFetch(
    `/api/v1/tweets/${tweetId}`,
    {
      method: 'DELETE'
    }
  );
  if (!response.success) {
    toast.error('删除推文失败，请稍后再试。', {
      description: response.error || '未知错误'
    });
    return;
  }
  toast.success('推文已成功删除。');
  fullTweets.value = fullTweets.value.filter(
    tweet => tweet.tweetId !== tweetId
  );
}

function handleReplyTweet(tweet: any) {
  console.log('Replying to tweet:', tweet.tweetId);
  // 在这里处理回复逻辑
}

// --- 转发相关的状态 ---

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref(null);
const isSubmittingRetweet = ref(false);

function handleRetweetTweet(tweet: any) {
  console.log('Retweeting tweet:', tweet.tweetId);
  // 在这里处理转发逻辑
  selectedTweetForRetweet.value = tweet;
  isRetweetModalOpen.value = true;
}

// 这个函数由 RetweetModal 的 @submit-retweet 事件触发
async function handleSubmitRetweet({
  content,
  originalTweetId
}: {
  content: any;
  originalTweetId: any;
}) {
  isSubmittingRetweet.value = true;
  try {
    const response: any = await apiFetch(
      '/api/v1/tweets/send-tweets',
      {
        method: 'POST',
        body: {
          content: content, // 用户的评论
          replyToTweetId: '', // 告知后端这是对哪条推文的转发
          retweetOfTweetId: originalTweetId, // 告知后端这是对哪条推文的转发
          quoteTweetId: '', // 如果是引用转发，这里可以传入原推文ID
          visibility: 'public', // 可选：设置可见性
          hashtags: '', // 可选：设置标签
          mentions: '', // 可选：设置提及用户
          scheduledAt: '', // 可选：设置定时发送时间
          location: '' // 可选：设置位置
        }
      }
    );

    console.log(
      'Submitting retweet with content:',
      content,
      'Original tweet ID:',
      originalTweetId
    );

    toast.success('转发成功！');

    if (!response.success) {
      throw new Error(response.message || '转发失败');
    }

    // 可选：刷新数据或乐观更新UI
  } catch (err: any) {
    console.error('Failed to retweet:', err);
    toast.error(err.message || '转发失败，请稍后重试。');
  } finally {
    isSubmittingRetweet.value = false;
    isRetweetModalOpen.value = false; // 确保模态框关闭
  }
}

async function handleLikeTweet(
  tweet: any,
  action: 'like' | 'unlike'
) {
  console.log('Liking tweet:', tweet, action);
  // 在这里处理点赞逻辑
  const response: any = await apiFetch(
    '/api/v1/interactions/like',
    {
      method: 'POST',
      body: {
        tweetId: tweet.tweetId,
        likeType: action
      }
    }
  );
  if (!response.success) {
    console.error(
      'Failed to like/unlike tweet:',
      response.error
    );
    return;
  }
}

async function handleBookmarkTweet(
  tweet: any,
  action: 'mark' | 'unmark'
) {
  console.log('Bookmarking tweet:', tweet, action);
  const response: any = await apiFetch(
    '/api/v1/interactions/bookmark',
    {
      method: 'POST',
      body: {
        tweetId: tweet.tweetId,
        bookmarkType: action
      }
    }
  );
  if (!response.success) {
    console.error(
      'Failed to bookmark/unbookmark tweet:',
      response.error
    );
    return;
  }
}
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
          (detailsError as Error)?.message || detailsError
        }}</pre>
      </div>

      <!-- 9. 【修复】模板使用最终处理好的 fullTweets 数组 -->
      <TweetList
        @delete-tweet="handleDeleteTweet"
        @reply-tweet="handleReplyTweet"
        @retweet-tweet="handleRetweetTweet"
        @like-tweet="handleLikeTweet"
        @bookmark-tweet="handleBookmarkTweet"
        v-else-if="fullTweets.length > 0"
        :tweets="fullTweets"
      />

      <RetweetModal
        v-if="selectedTweetForRetweet"
        v-model:open="isRetweetModalOpen"
        :tweet="selectedTweetForRetweet"
        :is-submitting="isSubmittingRetweet"
        @submit-retweet="handleSubmitRetweet"
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
