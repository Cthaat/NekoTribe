<script setup>
import TweetCard from '@/components/TweetCard.vue';
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';

// 你的推文数据，从API获取
const tweetData = {
  tweetId: 10005,
  content:
    '🎉 欢迎使用推特克隆系统！这是第一条测试推文，标志着我们平台的正式启动。感谢所有用户的支持！',
  authorId: 1120, // 这个ID与currentUserId匹配，所以会显示删除按钮
  username: 'admin',
  displayName: '系统管理员',
  avatarUrl: '/avatars/admin.png',
  isVerified: 1,
  replyToTweetId: null,
  retweetOfTweetId: null,
  quoteTweetId: null,
  isRetweet: 0,
  isQuoteTweet: 0,
  likesCount: 15,
  retweetsCount: 1,
  repliesCount: 2,
  viewsCount: 0,
  visibility: 'public',
  language: 'zh-CN',
  createdAt: '2025-07-08T00:14:27.723Z',
  engagementScore: 3,
  media: '' // 示例媒体
};
</script>

<template>
  <div class="bg-background p-10">
    <TweetCard :tweet="tweetData" />
  </div>
  <Pagination
    v-slot="{ page }"
    :items-per-page="10"
    :total="300"
    :default-page="2"
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
