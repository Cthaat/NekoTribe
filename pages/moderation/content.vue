<script setup lang="ts">
import { ref, computed, onMounted } from 'vue';
import { toast } from 'vue-sonner';
import ModerationStats from '@/components/ModerationStats.vue';
import ModerationFilters from '@/components/ModerationFilters.vue';
import ModerationList from '@/components/ModerationList.vue';
import ModerationDetailModal from '@/components/ModerationDetailModal.vue';
import type { ModerationTweet } from '@/components/ModerationCard.vue';
import type { ModerationStatsData } from '@/components/ModerationStats.vue';
import type { ModerationFiltersData } from '@/components/ModerationFilters.vue';

// ==================== 测试数据 ====================

// 模拟统计数据
const statsData = ref<ModerationStatsData>({
  pending: 23,
  approved: 156,
  rejected: 42,
  flagged: 8,
  todayProcessed: 31,
  avgProcessTime: '15分钟'
});

// 模拟推文数据
const mockTweets: ModerationTweet[] = [
  {
    id: 1,
    content:
      '这是一条包含敏感内容的测试推文，可能涉及到一些不当言论，需要审核人员仔细查看并做出判断。#测试 #审核',
    author: {
      id: 101,
      username: 'testuser1',
      nickname: '测试用户一',
      avatar: '/avatars/default.png',
      isVerified: true
    },
    media: [
      {
        type: 'image',
        url: 'https://picsum.photos/800/600?random=1'
      },
      {
        type: 'image',
        url: 'https://picsum.photos/800/600?random=2'
      }
    ],
    reportCount: 5,
    reportReasons: ['垃圾信息', '骚扰'],
    status: 'pending',
    createdAt: new Date(
      Date.now() - 2 * 60 * 60 * 1000
    ).toISOString(),
    reportedAt: new Date(
      Date.now() - 30 * 60 * 1000
    ).toISOString(),
    likes: 128,
    retweets: 34,
    replies: 12
  },
  {
    id: 2,
    content:
      '免费送iPhone 15 Pro Max！只需要关注+转发+私信即可参与抽奖！100%中奖率！点击链接立即领取 → bit.ly/fake-link\n\n#免费 #抽奖 #iPhone15',
    author: {
      id: 102,
      username: 'spammer2023',
      nickname: '幸运抽奖官方',
      avatar: '/avatars/default.png',
      isVerified: false
    },
    reportCount: 15,
    reportReasons: ['垃圾信息', '虚假信息'],
    status: 'pending',
    createdAt: new Date(
      Date.now() - 5 * 60 * 60 * 1000
    ).toISOString(),
    reportedAt: new Date(
      Date.now() - 1 * 60 * 60 * 1000
    ).toISOString(),
    likes: 8,
    retweets: 2,
    replies: 45
  },
  {
    id: 3,
    content:
      '今天天气真好，出门散步看到了很美的风景，和大家分享一下！🌸🌳',
    author: {
      id: 103,
      username: 'nature_lover',
      nickname: '自然爱好者',
      avatar: '/avatars/default.png',
      isVerified: false
    },
    media: [
      {
        type: 'image',
        url: 'https://picsum.photos/800/600?random=3'
      },
      {
        type: 'image',
        url: 'https://picsum.photos/800/600?random=4'
      },
      {
        type: 'image',
        url: 'https://picsum.photos/800/600?random=5'
      }
    ],
    reportCount: 1,
    reportReasons: ['其他'],
    status: 'pending',
    createdAt: new Date(
      Date.now() - 8 * 60 * 60 * 1000
    ).toISOString(),
    reportedAt: new Date(
      Date.now() - 2 * 60 * 60 * 1000
    ).toISOString(),
    likes: 256,
    retweets: 45,
    replies: 23
  },
  {
    id: 4,
    content:
      '某些人就是欠骂！看到这条推文的人必须转发，不然倒霉三年！这是真的！我朋友没转发结果...',
    author: {
      id: 104,
      username: 'chain_msg',
      nickname: '转发达人',
      avatar: '/avatars/default.png',
      isVerified: false
    },
    reportCount: 8,
    reportReasons: ['骚扰', '虚假信息'],
    status: 'pending',
    createdAt: new Date(
      Date.now() - 12 * 60 * 60 * 1000
    ).toISOString(),
    reportedAt: new Date(
      Date.now() - 3 * 60 * 60 * 1000
    ).toISOString(),
    likes: 12,
    retweets: 89,
    replies: 156
  },
  {
    id: 5,
    content:
      '分享一个超棒的编程教程，帮助我快速学会了Vue3！\n\n链接：https://example.com/vue3-tutorial\n\n强烈推荐给想学前端的朋友们！💻 #编程 #Vue3 #前端开发',
    author: {
      id: 105,
      username: 'dev_teacher',
      nickname: '编程导师',
      avatar: '/avatars/default.png',
      isVerified: true
    },
    reportCount: 2,
    reportReasons: ['垃圾信息'],
    status: 'pending',
    createdAt: new Date(
      Date.now() - 24 * 60 * 60 * 1000
    ).toISOString(),
    reportedAt: new Date(
      Date.now() - 4 * 60 * 60 * 1000
    ).toISOString(),
    likes: 512,
    retweets: 128,
    replies: 67
  },
  {
    id: 6,
    content:
      '这个视频太有意思了，记录了我家猫咪的日常生活🐱',
    author: {
      id: 106,
      username: 'cat_lover',
      nickname: '猫奴日记',
      avatar: '/avatars/default.png',
      isVerified: false
    },
    media: [
      {
        type: 'video',
        url: 'https://example.com/cat-video.mp4',
        thumbnail: 'https://picsum.photos/800/600?random=6'
      }
    ],
    reportCount: 1,
    reportReasons: ['成人内容'],
    status: 'flagged',
    createdAt: new Date(
      Date.now() - 36 * 60 * 60 * 1000
    ).toISOString(),
    reportedAt: new Date(
      Date.now() - 6 * 60 * 60 * 1000
    ).toISOString(),
    likes: 1024,
    retweets: 256,
    replies: 89
  }
];

// ==================== 状态管理 ====================

// 过滤器状态
const filters = ref<ModerationFiltersData>({
  search: '',
  status: 'all',
  reportReason: 'all',
  dateRange: 'all',
  sortBy: 'newest'
});

// 推文列表
const tweets = ref<ModerationTweet[]>([...mockTweets]);

// 加载状态
const loading = ref(false);

// 详情弹窗
const detailModalOpen = ref(false);
const selectedTweet = ref<ModerationTweet | null>(null);

// ==================== 过滤逻辑 ====================

const filteredTweets = computed(() => {
  let result = [...tweets.value];

  // 搜索过滤
  if (filters.value.search) {
    const searchLower = filters.value.search.toLowerCase();
    result = result.filter(
      t =>
        t.content.toLowerCase().includes(searchLower) ||
        t.author.username
          .toLowerCase()
          .includes(searchLower) ||
        t.author.nickname
          .toLowerCase()
          .includes(searchLower)
    );
  }

  // 状态过滤
  if (filters.value.status !== 'all') {
    result = result.filter(
      t => t.status === filters.value.status
    );
  }

  // 举报原因过滤
  if (filters.value.reportReason !== 'all') {
    const reasonMap: Record<string, string> = {
      spam: '垃圾信息',
      harassment: '骚扰',
      hate: '仇恨言论',
      violence: '暴力内容',
      adult: '成人内容',
      misinformation: '虚假信息',
      copyright: '侵权',
      other: '其他'
    };
    const reason = reasonMap[filters.value.reportReason];
    result = result.filter(t =>
      t.reportReasons.includes(reason)
    );
  }

  // 排序
  switch (filters.value.sortBy) {
    case 'newest':
      result.sort(
        (a, b) =>
          new Date(b.reportedAt).getTime() -
          new Date(a.reportedAt).getTime()
      );
      break;
    case 'oldest':
      result.sort(
        (a, b) =>
          new Date(a.reportedAt).getTime() -
          new Date(b.reportedAt).getTime()
      );
      break;
    case 'most_reports':
      result.sort((a, b) => b.reportCount - a.reportCount);
      break;
    case 'most_engagement':
      result.sort(
        (a, b) =>
          b.likes +
          b.retweets +
          b.replies -
          (a.likes + a.retweets + a.replies)
      );
      break;
  }

  return result;
});

// ==================== 事件处理 ====================

// 通过审核
const handleApprove = (id: number) => {
  const index = tweets.value.findIndex(t => t.id === id);
  if (index !== -1) {
    tweets.value[index].status = 'approved';
    statsData.value.pending--;
    statsData.value.approved++;
    statsData.value.todayProcessed++;
  }
};

// 拒绝推文
const handleReject = (id: number) => {
  const index = tweets.value.findIndex(t => t.id === id);
  if (index !== -1) {
    tweets.value[index].status = 'rejected';
    statsData.value.pending--;
    statsData.value.rejected++;
    statsData.value.todayProcessed++;
  }
};

// 标记审查
const handleFlag = (id: number) => {
  const index = tweets.value.findIndex(t => t.id === id);
  if (index !== -1) {
    tweets.value[index].status = 'flagged';
    statsData.value.pending--;
    statsData.value.flagged++;
  }
};

// 查看详情
const handleViewDetail = (tweet: ModerationTweet) => {
  selectedTweet.value = tweet;
  detailModalOpen.value = true;
};

// 详情弹窗中的审核操作
const handleDetailApprove = (id: number, note: string) => {
  handleApprove(id);
  if (note) {
    console.log(`审核备注 (通过): ${note}`);
  }
};

const handleDetailReject = (id: number, note: string) => {
  handleReject(id);
  if (note) {
    console.log(`审核备注 (拒绝): ${note}`);
  }
};

const handleDetailFlag = (id: number, note: string) => {
  handleFlag(id);
  if (note) {
    console.log(`审核备注 (标记): ${note}`);
  }
};

// 刷新列表
const handleRefresh = () => {
  loading.value = true;
  setTimeout(() => {
    // 模拟刷新
    tweets.value = [...mockTweets];
    loading.value = false;
    toast.success('列表已刷新');
  }, 1000);
};

// 加载更多
const handleLoadMore = () => {
  toast.info('没有更多内容了');
};

// 重置过滤器
const handleResetFilters = () => {
  toast.info('过滤器已重置');
};
</script>

<template>
  <div class="space-y-6">
    <!-- 统计面板 -->
    <ModerationStats :stats="statsData" />

    <!-- 过滤器 -->
    <ModerationFilters
      v-model="filters"
      @reset="handleResetFilters"
    />

    <!-- 审核列表 -->
    <ModerationList
      :tweets="filteredTweets"
      :loading="loading"
      @approve="handleApprove"
      @reject="handleReject"
      @flag="handleFlag"
      @view-detail="handleViewDetail"
      @refresh="handleRefresh"
      @load-more="handleLoadMore"
    />

    <!-- 详情弹窗 -->
    <ModerationDetailModal
      v-model:open="detailModalOpen"
      :tweet="selectedTweet"
      @approve="handleDetailApprove"
      @reject="handleDetailReject"
      @flag="handleDetailFlag"
    />
  </div>
</template>
