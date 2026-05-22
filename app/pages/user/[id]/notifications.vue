<script setup lang="ts">
import Mail from '@/components/Mail.vue';
import { ref, watch, computed } from 'vue';
import { useRoute } from 'vue-router';
import { toast } from 'vue-sonner';
import {
  v2BatchSetNotificationReadStatus,
  v2DeleteNotification,
  v2RestoreNotification,
  v2SetNotificationReadStatus
} from '@/services/notifications';
import { useNotificationMailbox } from '@/composables/useNotificationMailbox';
import type { NotificationVM } from '@/types/notifications';
import type { V2Json } from '@/types/v2';
import type {
  MailDetailItem,
  MailItem,
  MailPreview
} from '@/components/mail/types';

const { t } = useAppLocale();
const route = useRoute();
const localePath = useLocalePath();
const type = ref<string>(
  (route.query.type as string) || 'all'
);
const unreadOnly = ref(
  (route.query.unreadOnly as string) === 'true'
);
const showDeleted = ref(false);

const mailbox = useNotificationMailbox({
  type,
  unreadOnly,
  showDeleted,
  pageSize: 10
});

watch([type, unreadOnly, showDeleted], () => {
  mailbox.resetAndRefresh();
});

watch(
  mailbox.page,
  () => {
    mailbox.refresh();
  },
  { immediate: true }
);

function setLocalReadStatus(
  notificationId: number,
  read: boolean
) {
  mailbox.notifications.value =
    mailbox.notifications.value.map(item =>
      item.id === notificationId ? { ...item, read } : item
    );
}

async function handleReadMail(mailId: string) {
  const notificationId = Number(mailId);
  setLocalReadStatus(notificationId, true);
  try {
    await v2SetNotificationReadStatus(notificationId, {
      read: true
    });
  } catch {
    /* swallow read-status sync errors */
  }
}

async function handleSetMailReadStatus({
  mailId,
  read
}: {
  mailId: string;
  read: boolean;
}) {
  const notificationId = Number(mailId);
  setLocalReadStatus(notificationId, read);
  try {
    await v2SetNotificationReadStatus(notificationId, {
      read
    });
    toast.success(
      read
        ? t('notifications.mail.markReadSuccess')
        : t('notifications.mail.markUnreadSuccess')
    );
  } catch {
    setLocalReadStatus(notificationId, !read);
    toast.error(t('notifications.mail.readFailed'));
  }
}

async function handleMarkAllRead() {
  try {
    await v2BatchSetNotificationReadStatus({
      read: true
    });
    mailbox.notifications.value =
      mailbox.notifications.value.map(item => ({
        ...item,
        read: true
      }));
    toast.success(t('notifications.mail.markAllReadSuccess'));
  } catch {
    toast.error(t('notifications.mail.markAllReadFailed'));
  }
}

async function handleRefresh() {
  mailbox.page.value = 1;
  await mailbox.refresh();
}

function handleFilterChange(filters: {
  type: string;
  unreadOnly: boolean;
  showDeleted: boolean;
}) {
  type.value = filters.type;
  unreadOnly.value = filters.unreadOnly;
  showDeleted.value = filters.showDeleted;
}

async function handleDeleteMail(mailId: string) {
  const notificationId = Number(mailId);
  try {
    await v2DeleteNotification(notificationId);
    mailbox.notifications.value =
      mailbox.notifications.value.filter(
        item => item.id !== notificationId
      );
    toast.success(t('notifications.mail.deleteSuccess'));
  } catch {
    toast.error(t('notifications.mail.deleteFailed'));
  }
}

async function handleRestoreMail(mailId: string) {
  const notificationId = Number(mailId);
  try {
    await v2RestoreNotification(notificationId);
    mailbox.notifications.value =
      mailbox.notifications.value.filter(
        item => item.id !== notificationId
      );
    toast.success(t('notifications.mail.restoreSuccess'));
  } catch {
    toast.error(t('notifications.mail.restoreFailed'));
  }
}

type NotificationMetadata = { [key: string]: V2Json };

function metadataRecord(
  notification: NotificationVM
): NotificationMetadata {
  const metadata = notification.metadata;
  if (
    metadata &&
    typeof metadata === 'object' &&
    !Array.isArray(metadata)
  ) {
    return metadata;
  }
  return {};
}

function metadataString(
  metadata: NotificationMetadata,
  key: string
): string {
  const value = metadata[key];
  if (typeof value === 'string') return value;
  if (
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return String(value);
  }
  return '';
}

function metadataNumber(
  metadata: NotificationMetadata,
  key: string
): number | null {
  const value = metadata[key];
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value !== 'string') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function firstMetadataNumber(
  metadata: NotificationMetadata,
  keys: string[]
): number | null {
  for (const key of keys) {
    const value = metadataNumber(metadata, key);
    if (value !== null) return value;
  }
  return null;
}

function typeLabel(typeValue: string): string {
  const key = typeValue.replace(/-/g, '_');
  if (
    [
      'like',
      'comment',
      'retweet',
      'follow',
      'mention',
      'login_alert',
      'system',
      'group_invite'
    ].includes(key)
  ) {
    return t(`mail.types.${key}`);
  }
  return typeValue;
}

function priorityLabel(priority: string): string {
  if (['low', 'normal', 'high', 'urgent'].includes(priority)) {
    return t(`mail.priority.${priority}`);
  }
  return priority;
}

function compactText(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

function postIdForNotification(
  notification: NotificationVM,
  metadata: NotificationMetadata
): number | null {
  const metadataPostId = firstMetadataNumber(metadata, [
    'target_post_id',
    'post_id',
    'source_post_id'
  ]);
  if (metadataPostId !== null) return metadataPostId;

  return notification.resourceType === 'post'
    ? notification.resourceId
    : null;
}

function commentIdForNotification(
  notification: NotificationVM,
  metadata: NotificationMetadata
): number | null {
  const metadataCommentId = firstMetadataNumber(metadata, [
    'comment_id',
    'parent_comment_id'
  ]);
  if (metadataCommentId !== null) return metadataCommentId;

  return notification.resourceType === 'comment'
    ? notification.resourceId
    : null;
}

function resourceHref(
  notification: NotificationVM,
  metadata: NotificationMetadata
): string | null {
  const postId = postIdForNotification(notification, metadata);
  const commentId = commentIdForNotification(
    notification,
    metadata
  );
  if (postId) {
    const basePath = localePath(`/tweet/${postId}`);
    return commentId ? `${basePath}#comment-${commentId}` : basePath;
  }

  if (
    notification.resourceType === 'user' &&
    notification.resourceId
  ) {
    return localePath(
      `/user/${notification.resourceId}/profile`
    );
  }

  const targetUserId = metadataNumber(metadata, 'target_user_id');
  if (targetUserId) {
    return localePath(`/user/${targetUserId}/profile`);
  }

  if (notification.type === 'login_alert') {
    return localePath('/account/active');
  }

  if (notification.type === 'group_invite') {
    return localePath('/groups/invites');
  }

  return null;
}

function primaryActionLabel(notification: NotificationVM): string {
  if (notification.type === 'follow') {
    return t('mail.actions.viewProfile');
  }
  if (notification.type === 'login_alert') {
    return t('mail.actions.viewSession');
  }
  if (notification.resourceType === 'comment') {
    return t('mail.actions.viewComment');
  }
  if (notification.type === 'group_invite') {
    return t('mail.actions.viewInvite');
  }
  return t('mail.actions.viewTweet');
}

function buildPreview(
  title: string,
  text: string,
  to: string | null
): MailPreview | null {
  const compact = compactText(text);
  if (!compact) return null;
  return {
    title,
    text: compact,
    to
  };
}

function previewsForNotification(
  notification: NotificationVM,
  metadata: NotificationMetadata,
  href: string | null
): {
  primaryPreview: MailPreview | null;
  secondaryPreview: MailPreview | null;
} {
  const actionText =
    metadataString(metadata, 'comment_excerpt') ||
    metadataString(metadata, 'reply_excerpt') ||
    metadataString(metadata, 'quote_excerpt') ||
    metadataString(metadata, 'retweet_excerpt');
  const postText = metadataString(metadata, 'post_excerpt');
  const parentCommentText = metadataString(
    metadata,
    'parent_comment_excerpt'
  );

  const actionPreview = buildPreview(
    notification.resourceType === 'comment'
      ? t('mail.preview.comment')
      : t('mail.preview.action'),
    actionText,
    href
  );
  const postPreview = buildPreview(
    t('mail.preview.post'),
    postText,
    href
  );
  const parentPreview = buildPreview(
    t('mail.preview.parentComment'),
    parentCommentText,
    href
  );

  return {
    primaryPreview: actionPreview ?? postPreview,
    secondaryPreview: actionPreview
      ? postPreview ?? parentPreview
      : parentPreview
  };
}

function detailsForNotification(
  notification: NotificationVM,
  metadata: NotificationMetadata
): MailDetailItem[] {
  const details: MailDetailItem[] = [];
  const postId = postIdForNotification(notification, metadata);
  const commentId = commentIdForNotification(
    notification,
    metadata
  );
  const deviceInfo = metadataString(metadata, 'device_info');
  const ipAddress = metadataString(metadata, 'ip_address');
  const userAgent = metadataString(metadata, 'user_agent');

  if (postId) {
    details.push({
      label: t('mail.details.postId'),
      value: String(postId)
    });
  }
  if (commentId) {
    details.push({
      label: t('mail.details.commentId'),
      value: String(commentId)
    });
  }
  if (deviceInfo) {
    details.push({
      label: t('mail.details.device'),
      value: deviceInfo
    });
  }
  if (ipAddress) {
    details.push({
      label: t('mail.details.ipAddress'),
      value: ipAddress
    });
  }
  if (userAgent) {
    details.push({
      label: t('mail.details.userAgent'),
      value: userAgent
    });
  }
  if (notification.resourceType) {
    details.push({
      label: t('mail.details.resource'),
      value: `${notification.resourceType}${
        notification.resourceId
          ? ` #${notification.resourceId}`
          : ''
      }`
    });
  }

  return details;
}

function mapNotificationToMail(
  notification: NotificationVM
): MailItem {
  const metadata = metadataRecord(notification);
  const href = resourceHref(notification, metadata);
  const actorHref = notification.actor
    ? localePath(`/user/${notification.actor.id}/profile`)
    : null;
  const label = typeLabel(notification.type);
  const previews = previewsForNotification(
    notification,
    metadata,
    href
  );

  return {
    id: String(notification.id),
    avatar: notification.actor?.avatarUrl || '',
    name:
      notification.actor?.name ||
      notification.actor?.username ||
      t('notifications.mail.systemName'),
    email:
      notification.actor?.username ||
      t('notifications.mail.systemEmail'),
    subject: notification.title || label,
    text: notification.message,
    date: notification.createdAt,
    read: notification.read,
    labels: [label],
    type: notification.type,
    typeLabel: label,
    priority: notification.priority,
    priorityLabel: priorityLabel(notification.priority),
    href,
    actorHref,
    primaryActionLabel: primaryActionLabel(notification),
    details: detailsForNotification(notification, metadata),
    primaryPreview: previews.primaryPreview,
    secondaryPreview: previews.secondaryPreview
  };
}

const mails = computed(() =>
  mailbox.notifications.value.map(mapNotificationToMail)
);

const hasNoNotifications = computed(
  () => mailbox.notifications.value.length === 0
);
</script>

<template>
  <div class="flex min-h-[calc(100dvh-4rem)] flex-col">
    <Mail
      :mails="mails"
      :nav-collapsed-size="4"
      :load-more="mailbox.loadNextPage"
      :is-trash-view="showDeleted"
      :loading="mailbox.loading.value"
      @read-mail="handleReadMail"
      @delete-mail="handleDeleteMail"
      @restore-mail="handleRestoreMail"
      @set-read-status="handleSetMailReadStatus"
      @mark-all-read="handleMarkAllRead"
      @refresh="handleRefresh"
      @filter-change="handleFilterChange"
    />

    <div
      v-if="mailbox.error.value && hasNoNotifications"
      class="px-6 py-4 text-sm text-destructive"
    >
      {{ mailbox.error.value }}
    </div>
  </div>
</template>
