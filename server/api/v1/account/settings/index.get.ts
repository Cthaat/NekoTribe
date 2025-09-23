import { getUserSettings } from '@/server/utils/userSettingsStore';

/** 获取当前用户设置（含默认值回填） */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  const settings = await getUserSettings(auth.userId);
  return {
    success: true,
    message: '获取用户设置成功',
    data: { settings },
    code: 200,
    timestamp: new Date().toISOString()
  };
});
