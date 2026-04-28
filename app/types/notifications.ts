import type { V2Json, V2NotificationTypeFilter } from './v2';
import type { PageViewModel } from './posts';

export interface NotificationActorVM {
  id: number;
  username: string;
  name: string;
  avatarUrl: string;
}

export interface NotificationVM {
  id: number;
  type: string;
  title: string;
  message: string;
  resourceType: string | null;
  resourceId: number | null;
  priority: string;
  read: boolean;
  readAt: string | null;
  deletedAt: string | null;
  actor: NotificationActorVM | null;
  metadata: V2Json | null;
  createdAt: string;
}

export interface NotificationListRequestVM {
  page?: number;
  pageSize?: number;
  type?: V2NotificationTypeFilter | string;
  unreadOnly?: boolean;
  showDeleted?: boolean;
}

export interface SetNotificationReadStatusFormVM {
  read: boolean;
}

export interface BatchSetNotificationReadStatusFormVM {
  notificationIds?: number[];
  read: boolean;
}

export interface NotificationReadStatusVM {
  id: number;
  read: boolean;
  readAt: string | null;
}

export interface NotificationBatchReadStatusVM {
  updatedCount: number;
}

export interface RestoredNotificationVM {
  id: number;
  deletedAt: null;
}

export type NotificationPageVM = PageViewModel<NotificationVM>;
