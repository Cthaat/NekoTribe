import type { NotificationVM } from '@/types/notifications';
import { v2ListNotifications } from '@/services/notifications';
import { useRealtimeSocket } from '@/composables/useRealtimeSocket';
import { usePreferenceStore } from '@/stores/user';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';

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
  const app = useNuxtApp();
  const queue = authQueueFor(app);
  const realtime = useRealtimeSocket();
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
  let stopRecovery: (() => void) | null = null;
  let requestVersion = 0;
  let disposed = false;

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
    return import.meta.client && !disposed && preferenceStore.isLoggedIn && !queue.isIdentityChanging;
  }

  function captureOwner(): () => boolean {
    const authRevision = queue.revision;
    const owner = realtime.ownerRevision.value;
    return () => authRevision === queue.revision && owner === realtime.ownerRevision.value && canRequestNotifications();
  }

  function makeQueryKey(): string {
    return `${filters.type.value}|${filters.unreadOnly.value}|${filters.showDeleted.value}`;
  }

  async function refresh(): Promise<void> {
    const version = ++requestVersion;
    if (!canRequestNotifications()) {
      loading.value = false;
      error.value = import.meta.client ? '请先登录' : null;
      return;
    }

    loading.value = true;
    error.value = null;
    const sameOwner = captureOwner();
    const isCurrent = () => version === requestVersion && sameOwner();

    try {
      const currentKey = makeQueryKey();
      const isReset =
        currentKey !== lastQueryKey.value || page.value === 1;
      const result = await app.runWithContext(() => v2ListNotifications({
        type: filters.type.value,
        page: page.value,
        pageSize: pageSize.value,
        unreadOnly: filters.unreadOnly.value,
        showDeleted: filters.showDeleted.value
      }));
      if (!isCurrent()) return;

      const items = isReset ? [] : [...notifications.value];
      const seen = isReset ? new Set<number>() : new Set(seenIds.value);
      for (const item of result.items) {
        if (seen.has(item.id)) continue;
        seen.add(item.id);
        items.push(item);
      }
      lastQueryKey.value = currentKey;
      seenIds.value = seen;
      notifications.value = items;

      hasNext.value = result.hasNext;
    } catch (caught) {
      if (!isCurrent()) return;
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
      if (version === requestVersion) loading.value = false;
    }
  }

  function loadNextPage(): void {
    if (loading.value || !hasNext.value) return;
    page.value += 1;
  }

  function resetAndRefresh(): void {
    if (page.value !== 1) {
      requestVersion++;
      page.value = 1;
    }
    else if (canRequestNotifications()) void refresh();
  }

  if (import.meta.client) {
    onMounted(() => {
      unsubscribeRealtime = realtime.subscribe(message => {
        if (!canRequestNotifications()) return;
        if (realtimeEventTypes.has(message.type)) {
          resetAndRefresh();
        }
      });
      stopRecovery = watch(realtime.recoveryRevision, resetAndRefresh);
    });

    watch(realtime.ownerRevision, () => {
      requestVersion++;
      loading.value = false;
      notifications.value = [];
      seenIds.value = new Set();
      lastQueryKey.value = '';
      error.value = null;
      hasNext.value = false;
      page.value = 1;
    }, {flush: 'sync'});
    watch(realtime.ownerRevision, resetAndRefresh, {flush: 'post'});

    onBeforeUnmount(() => {
      disposed = true;
      requestVersion++;
      stopRecovery?.();
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
    captureOwner,
    refresh,
    loadNextPage,
    resetAndRefresh
  };
}
