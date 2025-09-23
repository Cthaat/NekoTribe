import { jwtDecode } from 'jwt-decode';
import { usePreferenceStore } from '~/stores/user'; // 导入您的 store

// --- 配置常量 ---
const REFRESH_THRESHOLD_SECONDS = 60; // 当 Token 剩余有效期少于60 秒时，触发刷新
const CHECK_INTERVAL_MILLISECONDS = 30 * 1000; // 每 30 秒检查一次

export default defineNuxtPlugin(nuxtApp => {
  // 一个变量来存储我们的定时器ID，以便后续可以清除它
  let heartbeatTimer: NodeJS.Timeout | null = null;

  /**
   * 核心的检查函数
   */
  const checkTokenExpiry = async () => {
    const store = usePreferenceStore();
    const accessToken = store.preferences.access_token;

    // 如果当前没有 token，就没必要检查了
    if (!accessToken) {
      if (heartbeatTimer) {
        console.log('[Heartbeat] 无 Token，停止心跳检查。');
        clearInterval(heartbeatTimer);
        heartbeatTimer = null;
      }
      return;
    }

    try {
      // 解码 Token 以获取其载荷 (payload)
      const decoded = jwtDecode<{ exp: number }>(
        accessToken
      );
      const nowInSeconds = Date.now() / 1000;

      const timeLeftInSeconds = decoded.exp - nowInSeconds;
      console.log(
        `[Heartbeat] Token 剩余有效期: ${Math.round(timeLeftInSeconds)} 秒`
      );

      // 如果剩余时间小于我们的阈值，就主动刷新
      if (timeLeftInSeconds < REFRESH_THRESHOLD_SECONDS) {
        console.log(
          `[Heartbeat] Token 即将过期，正在主动刷新...`
        );
        // 我们不关心刷新是否成功，让 store 内部的 try/catch 处理即可
        await store.refreshAccessToken();
      }
    } catch (error) {
      console.log(
        '[Heartbeat] 解码 Token 失败，可能是一个无效的 Token。',
        error
      );
      // 如果 token 无效，也应该停止检查
      if (heartbeatTimer) clearInterval(heartbeatTimer);
    }
  };

  /**
   * 启动心跳检查
   */
  const startHeartbeat = () => {
    // 防止重复启动
    if (heartbeatTimer) clearInterval(heartbeatTimer);

    console.log(
      `[Heartbeat] 启动 Token 健康检查，每 ${CHECK_INTERVAL_MILLISECONDS / 1000} 秒一次。`
    );
    // 先立即检查一次
    checkTokenExpiry();
    // 然后设置定时器
    heartbeatTimer = setInterval(
      checkTokenExpiry,
      CHECK_INTERVAL_MILLISECONDS
    );
  };

  /**
   * 停止心跳检查
   */
  const stopHeartbeat = () => {
    if (heartbeatTimer) {
      console.log('[Heartbeat] 停止 Token 健康检查。');
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
  };

  // --- 插件的核心逻辑：监听登录状态 ---

  // 监听 Pinia store 中 access_token 的变化
  const store = usePreferenceStore();
  watch(
    () => store.preferences.access_token,
    (newToken, oldToken) => {
      // 当用户从“未登录”变为“已登录”时
      if (newToken && !oldToken) {
        startHeartbeat();
      }
      // 当用户从“已登录”变为“未登录”时
      if (!newToken && oldToken) {
        stopHeartbeat();
      }
    },
    { immediate: true } // immediate: true 确保插件加载时立即执行一次，处理已登录的情况
  );
});
