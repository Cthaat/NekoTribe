import { watch } from 'vue';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '@/stores/user';
import { useRealtimeSocket } from '@/composables/useRealtimeSocket';

interface NotificationCreatedData {
  notification: {
    title?: string;
    message?: string;
    type?: string;
  };
}

function isNotificationCreatedData(
  data: Record<string, unknown> | undefined
): data is Record<string, unknown> & NotificationCreatedData {
  return (
    typeof data?.notification === 'object' &&
    data.notification !== null &&
    !Array.isArray(data.notification)
  );
}

export default defineNuxtPlugin(() => {
  const preferenceStore = usePreferenceStore();
  const realtime = useRealtimeSocket();

  realtime.subscribe(message => {
    if (
      message.type !== 'notification_created' ||
      !preferenceStore.preferences.push_notification_enabled ||
      !isNotificationCreatedData(message.data)
    ) {
      return;
    }

    const title =
      message.data.notification.title ||
      message.data.notification.type ||
      '新通知';
    toast.info(title, {
      description: message.data.notification.message
    });
  });

  watch(
    () => preferenceStore.isLoggedIn,
    loggedIn => {
      if (loggedIn) {
        realtime.connect();
      } else {
        realtime.disconnect();
      }
    },
    { immediate: true }
  );
});
