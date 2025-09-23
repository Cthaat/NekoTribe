import { updateUserSettings } from '@/server/utils/userSettingsStore';

/** 更新当前用户设置（以 patch 方式合并） */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  const body = await readBody<
    Partial<{
      twoFactorEnabled: boolean;
      loginAlerts: boolean;
      profile_visibility: 'public' | 'private';
      show_online_status: boolean;
      allow_dm_from_strangers: boolean;
      push_notification_enabled: boolean;
      email_notification_enabled: boolean;
    }>
  >(event);

  const updated = await updateUserSettings(
    auth.userId,
    body || {}
  );
  return {
    success: true,
    message: '更新用户设置成功',
    data: { settings: updated },
    code: 200,
    timestamp: new Date().toISOString()
  };
});
