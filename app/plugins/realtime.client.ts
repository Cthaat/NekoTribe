import { watch } from 'vue';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '@/stores/user';
import { useRealtimeSocket } from '@/composables/useRealtimeSocket';
import { useAppLocaleController } from '@/composables/useAppLocale';
import { authQueueFor } from '@/services/auth-request-queue';
import { showDesktopNotification } from '@/utils/desktop-notifications';

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
  const localePath = useLocalePath();
  const identity = authQueueFor(app);
  let desktopNotification: Notification | null = null;
  let reportedUnavailable = false;

  function closeDesktopNotification() {
    desktopNotification?.close();
    desktopNotification = null;
  }

  function closeWhenVisible() {
    if (document.visibilityState === 'visible') closeDesktopNotification();
  }
  document.addEventListener('visibilitychange', closeWhenVisible);
  const stopIdentity = identity.subscribe(closeDesktopNotification);

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
    if (!preferenceStore.isLoggedIn || identity.isIdentityChanging) return;
    const userId = preferenceStore.preferences.user.id;
    const revision = identity.revision;
    const owner = realtime.ownerRevision.value;
    const type = message.data.notification.type;
    const nextDesktopNotification = showDesktopNotification({
      userId, type: typeof type === 'string' ? type : '', settings: preferenceStore.preferences,
      title: t('notifications.desktop.title'), body: t('notifications.desktop.body'),
      activate: () => {
        if (identity.revision !== revision || realtime.ownerRevision.value !== owner ||
            !preferenceStore.isLoggedIn || preferenceStore.preferences.user.id !== userId) return;
        window.focus();
        void app.runWithContext(() => navigateTo(localePath(`/user/${userId}/notifications`)));
      },
    });
    if (nextDesktopNotification) {
      closeDesktopNotification();
      desktopNotification = nextDesktopNotification;
    }
  });

  const stopOwner = watch(realtime.ownerRevision, () => {
    reportedUnavailable = false;
    closeDesktopNotification();
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
    stopIdentity();
    stopOwner();
    stopStatus();
    document.removeEventListener('visibilitychange', closeWhenVisible);
    closeDesktopNotification();
    realtime.disconnect();
  });
});
