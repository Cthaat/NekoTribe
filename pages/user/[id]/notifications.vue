<script setup lang="ts">
import Mail from '@/components/Mail.vue';
import { ref, watch, computed } from 'vue';
import { useRoute } from 'vue-router';
import { useApiFetch } from '@/composables/useApiFetch';
import { toast } from 'vue-sonner';

// 基础分页与筛选参数
const route = useRoute();
const page = ref(1);
const pageSize = ref(10);
const type = ref<string>(
  (route.query.type as string) || 'all'
);
// 后端读取的是字符串 'true'/'false'，这里保持一致
const unreadOnly = ref<string>(
  (route.query.unreadOnly as string) === 'true'
    ? 'true'
    : 'false'
);

// 通知项与响应类型（提取最常用字段，便于页面展示）
type NotificationItem = {
  notificationId: string;
  userId?: string;
  type: string;
  title: string;
  message: string;
  relatedType?: string;
  relatedId?: string;
  actorId?: string;
  isRead: number;
  priority?: string;
  createdAt: string;
  readAt?: string;
  actorUsername?: string;
  actorDisplayName?: string;
  actorAvatarUrl?: string;
};

interface NotificationListApiResponse {
  success?: boolean;
  message?: string;
  code?: number;
  data?: {
    type?:
      | 'all'
      | 'like'
      | 'retweet'
      | 'comment'
      | 'follow'
      | 'mention'
      | 'system';
    page?: number;
    pageSize?: number;
    notifications?: NotificationItem[];
    totalCount?: number;
    unreadOnly?: boolean | string;
    hasNext?: boolean;
    hasPrev?: boolean;
    totalPages?: number;
  };
}

// 列表数据容器
const notifications = ref<NotificationItem[]>([]);
// 已加载去重集合（按 notificationId）
const seenIds = ref<Set<string>>(new Set());

// 生成查询键用于判断筛选是否变化
const makeQueryKey = () =>
  `${route.params.id || ''}|${type.value}|${unreadOnly.value}`;
const lastQueryKey = ref<string>(makeQueryKey());

// 调用封装的 useApiFetch 获取通知列表
const {
  data: listApiResponse,
  pending: listPending,
  error: listError,
  refresh: refreshList
} = useApiFetch<NotificationListApiResponse>(
  '/api/v1/notifications/list',
  {
    query: {
      type,
      page,
      pageSize,
      unreadOnly
    },
    // 跟随分页/筛选和路由变化自动刷新
    watch: [
      page,
      pageSize,
      type,
      unreadOnly,
      () => route.params.id
    ]
  }
);

// 同步响应到本地状态，保证 .value 使用正确
watch(
  listApiResponse,
  newVal => {
    if (listError.value) {
      notifications.value = [];
      seenIds.value = new Set();
      return;
    }
    if (!newVal?.data?.notifications) {
      // 没有新数据时不清空，保持已加载数据
      return;
    }
    try {
      const currentKey = makeQueryKey();
      const isFilterChanged =
        currentKey !== lastQueryKey.value;
      const isFirstPage = (newVal.data.page || 1) === 1;

      // 当筛选变更或是第一页时，重置列表与去重集合
      if (isFilterChanged || isFirstPage) {
        notifications.value = [];
        seenIds.value = new Set();
        lastQueryKey.value = currentKey;
      }

      // 追加新页数据（带去重）
      for (const item of newVal.data.notifications) {
        if (!seenIds.value.has(item.notificationId)) {
          seenIds.value.add(item.notificationId);
          notifications.value.push(item);
        }
      }
      console.log(notifications);
    } catch (err: any) {
      console.error('加载通知列表失败:', err);
      if (process.client) {
        toast.error('加载通知失败，部分内容可能无法显示。');
      }
    }
  },
  { immediate: true }
);

// 加载与错误状态
const isLoading = computed(() => listPending.value);
const hasError = computed(() => !!listError.value);

// 统计信息
const totalCount = computed(
  () => listApiResponse.value?.data?.totalCount || 0
);

// 分页元数据与“是否还有下一页”
const hasNext = computed(
  () => !!listApiResponse.value?.data?.hasNext
);

// 加载下一页（供“加载更多/无限滚动”调用）
function loadNextPage() {
  if (isLoading.value) return;
  if (!hasNext.value) return;
  page.value = (page.value || 1) + 1;
}

// 当筛选项变化时，重置页码并主动刷新
watch([type, unreadOnly, () => route.params.id], () => {
  page.value = 1;
  // 重置由 listApiResponse watcher 处理
  refreshList();
});
</script>

<template>
  <div class="hidden flex-col md:flex">
    <Mail
      :mails="
        notifications.map(n => ({
          id: String(n.notificationId),
          avatar: n.actorAvatarUrl || '',
          name:
            n.actorDisplayName ||
            n.actorUsername ||
            'System',
          email: n.actorUsername || 'system',
          subject: n.title || n.type,
          text: n.message,
          date: n.createdAt,
          read: !!n.isRead,
          labels: [n.type]
        }))
      "
      :nav-collapsed-size="4"
      :load-more="loadNextPage"
    />
  </div>
</template>
