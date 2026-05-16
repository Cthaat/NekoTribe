import type { NotificationVM } from '@/types/notifications';
import { v2ListNotifications } from '@/services/notifications';
import { useRealtimeSocket } from '@/composables/useRealtimeSocket';
import { usePreferenceStore } from '@/stores/user';

interface NotificationMailboxFilters {
  type: Ref<string>;
  unreadOnly: Ref<boolean>;
  showDeleted: Ref<boolean>;
  pageSize?: number;
}

export function useNotificationMailbox(
  filters: NotificationMailboxFilters
) {
  const preferenceStore = usePreferenceStore();
  const page = ref(1);
  const pageSize = ref(filters.pageSize ?? 10);
  const notifications = shallowRef<NotificationVM[]>([]);
  const loading = ref(false);
  const error = ref<string | null>(null);
  const hasNext = ref(false);
  const seenIds = ref<Set<number>>(new Set());
  const lastQueryKey = ref('');
  const realtimeEventTypes = new Set([
    'notification_created',
    'notification_read_status_updated',
    'notifications_read_status_updated',
    'notification_deleted',
    'notification_restored'
  ]);
  let unsubscribeRealtime: (() => void) | null = null;

  function isUnauthorizedError(error: unknown): boolean {
    const candidate = error as {
      statusCode?: number;
      response?: { status?: number };
      data?: { code?: number };
    };
    return (
      candidate?.statusCode === 401 ||
      candidate?.response?.status === 401 ||
      candidate?.data?.code === 401
    );
  }

  function canRequestNotifications(): boolean {
    return import.meta.client && preferenceStore.isLoggedIn;
  }

  function makeQueryKey(): string {
    return `${filters.type.value}|${filters.unreadOnly.value}|${filters.showDeleted.value}`;
  }

  async function refresh(): Promise<void> {
    if (!canRequestNotifications()) {
      loading.value = false;
      error.value = import.meta.client ? '请先登录' : null;
      return;
    }

    loading.value = true;
    error.value = null;

    try {
      const currentKey = makeQueryKey();
      const isReset =
        currentKey !== lastQueryKey.value || page.value === 1;
      const result = await v2ListNotifications({
        type: filters.type.value,
        page: page.value,
        pageSize: pageSize.value,
        unreadOnly: filters.unreadOnly.value,
        showDeleted: filters.showDeleted.value
      });

      if (isReset) {
        notifications.value = [];
        seenIds.value = new Set();
        lastQueryKey.value = currentKey;
      }

      for (const item of result.items) {
        if (!seenIds.value.has(item.id)) {
          seenIds.value.add(item.id);
          notifications.value.push(item);
        }
      }

      hasNext.value = result.hasNext;
    } catch (caught) {
      if (isUnauthorizedError(caught)) {
        error.value = '请先登录';
        preferenceStore.clearAuthState();
        return;
      }

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
    if (!canRequestNotifications()) return;
    refresh();
  }

  if (import.meta.client) {
    onMounted(() => {
      const realtime = useRealtimeSocket();
      unsubscribeRealtime = realtime.subscribe(message => {
        if (!canRequestNotifications()) return;
        if (realtimeEventTypes.has(message.type)) {
          resetAndRefresh();
        }
      });
    });

    onBeforeUnmount(() => {
      unsubscribeRealtime?.();
      unsubscribeRealtime = null;
    });
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
