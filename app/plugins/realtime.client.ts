import { watch } from 'vue';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '@/stores/user';
import { useRealtimeSocket } from '@/composables/useRealtimeSocket';
import { useAppLocaleController } from '@/composables/useAppLocale';

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

export default defineNuxtPlugin(app => {
  const preferenceStore = usePreferenceStore();
  const realtime = useRealtimeSocket();
  const {t} = useAppLocaleController();
  let reportedUnavailable = false;

  const unsubscribe = realtime.subscribe(message => {
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

  const stopOwner = watch(realtime.ownerRevision, () => {
    reportedUnavailable = false;
  }, {flush: 'sync'});
  const stopStatus = watch(realtime.remoteEvents, state => {
    if (state === 'connected') reportedUnavailable = false;
    if (state === 'unavailable' && !reportedUnavailable) {
      reportedUnavailable = true;
      toast.info(t('notifications.realtimeUnavailable'));
    }
  });

  app.vueApp.onUnmount(() => {
    unsubscribe();
    stopOwner();
    stopStatus();
    realtime.disconnect();
  });
});
