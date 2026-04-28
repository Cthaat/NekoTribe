<script setup lang="ts">
import Mail from '@/components/Mail.vue';
import { ref, watch, computed } from 'vue';
import { useRoute } from 'vue-router';
import { toast } from 'vue-sonner';
import {
  v2DeleteNotification,
  v2RestoreNotification,
  v2SetNotificationReadStatus
} from '@/services/notifications';
import { useNotificationMailbox } from '@/composables/useNotificationMailbox';

const route = useRoute();
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

const mailRef = ref<InstanceType<typeof Mail>>();
watch(
  () => mailRef.value?.currentView,
  newView => {
    showDeleted.value = newView === 'trash';
    mailbox.resetAndRefresh();
  }
);

watch([type, unreadOnly], () => {
  mailbox.resetAndRefresh();
});

watch(
  mailbox.page,
  () => {
    mailbox.refresh();
  },
  { immediate: true }
);

async function handleReadMail(mailId: string) {
  const notificationId = Number(mailId);
  const mail = mailbox.notifications.value.find(
    item => item.id === notificationId
  );
  if (mail) {
    mail.read = true;
  }
  try {
    await v2SetNotificationReadStatus(notificationId, {
      read: true
    });
  } catch (error) {
    console.error('标记邮件为已读失败:', error);
  }
}

async function handleDeleteMail(mailId: string) {
  const notificationId = Number(mailId);
  try {
    await v2DeleteNotification(notificationId);
    mailbox.notifications.value =
      mailbox.notifications.value.filter(
        item => item.id !== notificationId
      );
    toast.success('邮件已移至垃圾桶');
  } catch (error) {
    console.error('移至垃圾桶失败:', error);
    toast.error('移至垃圾桶失败');
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
    toast.success('邮件已恢复');
  } catch (error) {
    console.error('恢复邮件失败:', error);
    toast.error('恢复邮件失败');
  }
}

const mails = computed(() =>
  mailbox.notifications.value.map(notification => ({
    id: String(notification.id),
    avatar: notification.actor?.avatarUrl || '',
    name:
      notification.actor?.name ||
      notification.actor?.username ||
      'System',
    email: notification.actor?.username || 'system',
    subject: notification.title || notification.type,
    text: notification.message,
    date: notification.createdAt,
    read: notification.read,
    labels: [notification.type]
  }))
);
</script>

<template>
  <div class="hidden flex-col md:flex">
    <Mail
      ref="mailRef"
      :mails="mails"
      :nav-collapsed-size="4"
      :load-more="mailbox.loadNextPage"
      :is-trash-view="showDeleted"
      @read-mail="handleReadMail"
      @delete-mail="handleDeleteMail"
      @restore-mail="handleRestoreMail"
    />

    <div
      v-if="mailbox.error && mailbox.notifications.length === 0"
      class="px-6 py-4 text-sm text-destructive"
    >
      {{ mailbox.error }}
    </div>
  </div>
</template>
