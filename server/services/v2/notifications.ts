import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import {
  v2Auth,
  v2Body,
  v2Boolean,
  v2Count,
  v2DateString,
  v2Execute,
  v2JsonValue,
  v2NotFound,
  v2Null,
  v2Number,
  v2NumberArray,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryString,
  v2RequiredNumber,
  v2Rows,
  v2String
} from '~/server/utils/v2';
import {
  v2GetPublicUser,
  v2MapNotification
} from '~/server/models/v2';

export async function v2ListNotifications(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2Notification[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const type = v2QueryString(event, 'type', 'all');
  const unreadOnly =
    v2QueryString(event, 'unread_only', 'false') === 'true';
  const showDeleted =
    v2QueryString(event, 'show_deleted', 'false') === 'true';
  const filters = [
    'user_id = :user_id',
    showDeleted ? 'deleted_at IS NOT NULL' : 'deleted_at IS NULL'
  ];
  const binds: Record<string, string | number> = {
    user_id: auth.userId
  };
  if (type && type !== 'all') {
    filters.push('type = :type');
    binds.type = type;
  }
  if (unreadOnly) {
    filters.push('is_read = 0');
  }
  const whereClause = filters.join('\n      AND ');
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_notifications
    WHERE ${whereClause}
    `,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        notification_id,
        actor_id,
        type,
        title,
        message,
        resource_type,
        resource_id,
        priority,
        is_read,
        read_at,
        deleted_at,
        metadata_json,
        created_at,
        ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn
      FROM n_notifications
      WHERE ${whereClause}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  const notifications = await Promise.all(
    rows.map(async row =>
      v2MapNotification(
        row,
        row.ACTOR_ID
          ? await v2GetPublicUser(
              connection,
              auth.userId,
              v2Number(row.ACTOR_ID)
            )
          : null
      )
    )
  );
  return v2Ok(
    notifications,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2SetNotificationReadStatus(
  event: H3Event,
  connection: oracledb.Connection,
  notificationId: number
): Promise<V2Response<V2NotificationReadData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2NotificationReadPayload = {
    is_read: v2Boolean(body.is_read)
  };
  const updated = await v2Execute(
    connection,
    `
    UPDATE n_notifications
    SET is_read = :is_read,
        read_at = CASE WHEN :is_read = 1 THEN CURRENT_TIMESTAMP ELSE NULL END
    WHERE notification_id = :notification_id
      AND user_id = :user_id
    `,
    {
      is_read: payload.is_read ? 1 : 0,
      notification_id: notificationId,
      user_id: auth.userId
    }
  );
  if (updated === 0) v2NotFound('通知不存在');
  const row = await v2One(
    connection,
    `
    SELECT notification_id, is_read, read_at
    FROM n_notifications
    WHERE notification_id = :notification_id
    `,
    { notification_id: notificationId }
  );
  if (!row) v2NotFound('通知不存在');
  return v2Ok({
    notification_id: v2Number(row.NOTIFICATION_ID),
    is_read: v2Number(row.IS_READ),
    read_at: v2DateString(row.READ_AT)
  });
}

export async function v2BatchSetNotificationReadStatus(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2NotificationBatchReadData>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2NotificationBatchReadPayload = {
    notification_ids: v2NumberArray(body.notification_ids),
    is_read: v2Boolean(body.is_read)
  };
  const isRead = payload.is_read ? 1 : 0;
  if (
    !payload.notification_ids ||
    payload.notification_ids.length === 0
  ) {
    const updated = await v2Execute(
      connection,
      `
      UPDATE n_notifications
      SET is_read = :is_read,
          read_at = CASE WHEN :is_read = 1 THEN CURRENT_TIMESTAMP ELSE NULL END
      WHERE user_id = :user_id
        AND deleted_at IS NULL
      `,
      { is_read: isRead, user_id: auth.userId }
    );
    return v2Ok({ updated_count: updated });
  }

  let updated = 0;
  for (const notificationId of payload.notification_ids) {
    updated += await v2Execute(
      connection,
      `
      UPDATE n_notifications
      SET is_read = :is_read,
          read_at = CASE WHEN :is_read = 1 THEN CURRENT_TIMESTAMP ELSE NULL END
      WHERE notification_id = :notification_id
        AND user_id = :user_id
      `,
      {
        is_read: isRead,
        notification_id: notificationId,
        user_id: auth.userId
      }
    );
  }
  return v2Ok({ updated_count: updated });
}

export async function v2DeleteNotification(
  event: H3Event,
  connection: oracledb.Connection,
  notificationId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const updated = await v2Execute(
    connection,
    `
    UPDATE n_notifications
    SET deleted_at = CURRENT_TIMESTAMP
    WHERE notification_id = :notification_id
      AND user_id = :user_id
      AND deleted_at IS NULL
    `,
    {
      notification_id: notificationId,
      user_id: auth.userId
    }
  );
  if (updated === 0) v2NotFound('通知不存在');
  return v2Null('notification deleted');
}

export async function v2RestoreNotification(
  event: H3Event,
  connection: oracledb.Connection,
  notificationId: number
): Promise<
  V2Response<{
    notification_id: number;
    deleted_at: null;
  }>
> {
  const auth = v2Auth(event);
  const updated = await v2Execute(
    connection,
    `
    UPDATE n_notifications
    SET deleted_at = NULL
    WHERE notification_id = :notification_id
      AND user_id = :user_id
    `,
    {
      notification_id: notificationId,
      user_id: auth.userId
    }
  );
  if (updated === 0) v2NotFound('通知不存在');
  return v2Ok({
    notification_id: notificationId,
    deleted_at: null
  });
}

export function v2NotificationId(value: string): number {
  return v2RequiredNumber(value, 'notification_id');
}

export function v2NotificationMetadata(
  value: unknown
): V2Json | null {
  return v2JsonValue(value);
}

export function v2NotificationType(value: unknown): string {
  return v2String(value);
}
