import {
  v2BatchSetNotificationReadStatus as apiBatchSetNotificationReadStatus,
  v2DeleteNotification,
  v2ListNotifications as apiListNotifications,
  v2RestoreNotification as apiRestoreNotification,
  v2SetNotificationReadStatus as apiSetNotificationReadStatus
} from '@/api/v2/notifications';
import type {
  V2ApiMeta,
  V2Notification,
  V2NotificationBatchReadData,
  V2NotificationBatchReadPayload,
  V2NotificationReadData,
  V2NotificationReadPayload,
  V2PagedResult
} from '@/types/v2';
import type { PageViewModel } from '@/types/posts';
import type {
  BatchSetNotificationReadStatusFormVM,
  NotificationActorVM,
  NotificationBatchReadStatusVM,
  NotificationListRequestVM,
  NotificationPageVM,
  NotificationReadStatusVM,
  NotificationVM,
  RestoredNotificationVM,
  SetNotificationReadStatusFormVM
} from '@/types/notifications';
import { normalizeAvatarUrl } from '@/utils/assets';

export { v2DeleteNotification };

function mapPageMeta<TDto, TViewModel>(
  result: V2PagedResult<TDto>,
  items: TViewModel[]
): PageViewModel<TViewModel> {
  const meta: V2ApiMeta | null = result.meta;
  return {
    items,
    total: meta?.total ?? items.length,
    page: meta?.page ?? 1,
    pageSize: meta?.page_size ?? items.length,
    hasNext: meta?.has_next ?? false
  };
}

function mapNotificationActor(
  actor: V2Notification['actor']
): NotificationActorVM | null {
  if (!actor) return null;

  return {
    id: actor.user_id,
    username: actor.username,
    name: actor.display_name,
    avatarUrl: normalizeAvatarUrl(actor.avatar_url)
  };
}

function mapNotification(dto: V2Notification): NotificationVM {
  return {
    id: dto.notification_id,
    type: dto.type,
    title: dto.title,
    message: dto.message,
    resourceType: dto.resource_type,
    resourceId: dto.resource_id,
    priority: dto.priority,
    read: dto.is_read === 1,
    readAt: dto.read_at,
    deletedAt: dto.deleted_at,
    actor: mapNotificationActor(dto.actor),
    metadata: dto.metadata,
    createdAt: dto.created_at
  };
}

function mapListRequest(
  request: NotificationListRequestVM
): {
  page?: number;
  page_size?: number;
  type?: string;
  unread_only?: boolean;
  show_deleted?: boolean;
} {
  return {
    page: request.page,
    page_size: request.pageSize,
    type: request.type,
    unread_only: request.unreadOnly,
    show_deleted: request.showDeleted
  };
}

function mapReadForm(
  form: SetNotificationReadStatusFormVM
): V2NotificationReadPayload {
  return {
    is_read: form.read
  };
}

function mapBatchReadForm(
  form: BatchSetNotificationReadStatusFormVM
): V2NotificationBatchReadPayload {
  return {
    notification_ids: form.notificationIds,
    is_read: form.read
  };
}

function mapReadResult(
  dto: V2NotificationReadData
): NotificationReadStatusVM {
  return {
    id: dto.notification_id,
    read: dto.is_read === 1,
    readAt: dto.read_at
  };
}

function mapBatchReadResult(
  dto: V2NotificationBatchReadData
): NotificationBatchReadStatusVM {
  return {
    updatedCount: dto.updated_count
  };
}

export async function v2ListNotifications(
  request: NotificationListRequestVM = {}
): Promise<NotificationPageVM> {
  const result = await apiListNotifications(mapListRequest(request));
  return mapPageMeta(result, result.items.map(mapNotification));
}

export async function v2SetNotificationReadStatus(
  notificationId: number,
  form: SetNotificationReadStatusFormVM
): Promise<NotificationReadStatusVM> {
  return mapReadResult(
    await apiSetNotificationReadStatus(
      notificationId,
      mapReadForm(form)
    )
  );
}

export async function v2BatchSetNotificationReadStatus(
  form: BatchSetNotificationReadStatusFormVM
): Promise<NotificationBatchReadStatusVM> {
  return mapBatchReadResult(
    await apiBatchSetNotificationReadStatus(
      mapBatchReadForm(form)
    )
  );
}

export async function v2RestoreNotification(
  notificationId: number
): Promise<RestoredNotificationVM> {
  const result = await apiRestoreNotification(notificationId);
  return {
    id: result.notification_id,
    deletedAt: result.deleted_at
  };
}
