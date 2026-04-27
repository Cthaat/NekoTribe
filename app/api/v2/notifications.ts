import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import type {
  V2Notification,
  V2NotificationBatchReadData,
  V2NotificationBatchReadPayload,
  V2NotificationReadData,
  V2NotificationReadPayload,
  V2PagedResult
} from '@/types/v2';

export async function v2ListNotifications(query: {
  page?: number;
  page_size?: number;
  type?: string;
  unread_only?: boolean;
  show_deleted?: boolean;
} = {}): Promise<V2PagedResult<V2Notification>> {
  const response = await v2Request<
    V2Notification[],
    undefined,
    {
      page?: number;
      page_size?: number;
      type?: string;
      unread_only?: 'true' | 'false';
      show_deleted?: 'true' | 'false';
    }
  >('/api/v2/notifications', {
    method: 'GET',
    query: {
      page: query.page,
      page_size: query.page_size,
      type: query.type,
      unread_only:
        query.unread_only === undefined
          ? undefined
          : query.unread_only
            ? 'true'
            : 'false',
      show_deleted:
        query.show_deleted === undefined
          ? undefined
          : query.show_deleted
            ? 'true'
            : 'false'
    }
  });
  return toV2PagedResult(response);
}

export async function v2SetNotificationReadStatus(
  notificationId: number,
  payload: V2NotificationReadPayload
): Promise<V2NotificationReadData> {
  return await v2RequestData<
    V2NotificationReadData,
    V2NotificationReadPayload
  >(`/api/v2/notifications/${notificationId}/read-status`, {
    method: 'PUT',
    body: payload
  });
}

export async function v2BatchSetNotificationReadStatus(
  payload: V2NotificationBatchReadPayload
): Promise<V2NotificationBatchReadData> {
  return await v2RequestData<
    V2NotificationBatchReadData,
    V2NotificationBatchReadPayload
  >('/api/v2/notifications/read-status', {
    method: 'PUT',
    body: payload
  });
}

export async function v2DeleteNotification(
  notificationId: number
): Promise<void> {
  await v2RequestData<null>(`/api/v2/notifications/${notificationId}`, {
    method: 'DELETE'
  });
}

export async function v2RestoreNotification(
  notificationId: number
): Promise<{
  notification_id: number;
  deleted_at: null;
}> {
  return await v2RequestData<{
    notification_id: number;
    deleted_at: null;
  }>(`/api/v2/notifications/${notificationId}/restore-status`, {
    method: 'PUT'
  });
}

