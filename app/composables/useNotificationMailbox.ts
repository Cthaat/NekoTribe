import type { V2Notification } from '@/types/v2';
import { v2ListNotifications } from '@/services/notifications';

interface NotificationMailboxFilters {
  type: Ref<string>;
  unreadOnly: Ref<boolean>;
  showDeleted: Ref<boolean>;
  pageSize?: number;
}

export function useNotificationMailbox(
  filters: NotificationMailboxFilters
) {
  const page = ref(1);
  const pageSize = ref(filters.pageSize ?? 10);
  const notifications = shallowRef<V2Notification[]>([]);
  const loading = ref(false);
  const error = ref<string | null>(null);
  const hasNext = ref(false);
  const seenIds = ref<Set<number>>(new Set());
  const lastQueryKey = ref('');

  function makeQueryKey(): string {
    return `${filters.type.value}|${filters.unreadOnly.value}|${filters.showDeleted.value}`;
  }

  async function refresh(): Promise<void> {
    loading.value = true;
    error.value = null;

    try {
      const currentKey = makeQueryKey();
      const isReset =
        currentKey !== lastQueryKey.value || page.value === 1;
      const result = await v2ListNotifications({
        type: filters.type.value,
        page: page.value,
        page_size: pageSize.value,
        unread_only: filters.unreadOnly.value,
        show_deleted: filters.showDeleted.value
      });

      if (isReset) {
        notifications.value = [];
        seenIds.value = new Set();
        lastQueryKey.value = currentKey;
      }

      for (const item of result.items) {
        if (!seenIds.value.has(item.notification_id)) {
          seenIds.value.add(item.notification_id);
          notifications.value.push(item);
        }
      }

      hasNext.value = !!result.meta?.has_next;
    } catch (caught) {
      error.value =
        caught instanceof Error
          ? caught.message
          : '加载通知失败';
      if (page.value === 1) {
        notifications.value = [];
        seenIds.value = new Set();
      }
    } finally {
      loading.value = false;
    }
  }

  function loadNextPage(): void {
    if (loading.value || !hasNext.value) return;
    page.value += 1;
  }

  function resetAndRefresh(): void {
    page.value = 1;
    refresh();
  }

  return {
    page,
    pageSize,
    notifications,
    loading,
    error,
    hasNext,
    refresh,
    loadNextPage,
    resetAndRefresh
  };
}
