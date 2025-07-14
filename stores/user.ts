import { defineStore } from 'pinia';
import { computed } from 'vue';
import type { UserPreference, ThemeMode } from './type';

// --- 默认状态 ---
// 这个对象保持不变，它定义了所有用户偏好的初始值。
const defaultPreferences: UserPreference = {
  // 主题相关
  theme_mode: 'system',
  font_size: 'normal',
  language: 'en',
  // 隐私和安全
  show_online_status: true,
  allow_dm_from_strangers: false,
  profile_visibility: 'public',
  // 通知设置
  push_notification_enabled: true,
  email_notification_enabled: true,
  notify_like: true,
  notify_comment: true,
  notify_follow: true,
  notify_mention: true,
  // 功能开关
  auto_play_video: true,
  show_sensitive_content: false,
  compact_mode: false,
  // 个性化体验
  default_home_tab: 'timeline',
  badge_display: true,
  // 可选数组
  mute_keywords: [],
  blocked_users: [],
  // 用户登录相关
  access_token: '', // 初始值为空字符串
  refresh_token: '', // 初始值为空字符串
  // 用户信息对象
  user: {
    userId: 0,
    email: '', // 邮箱
    username: '', // 用户名
    passwordHash: '', // 密码哈希
    avatarUrl: '', // 头像地址
    displayName: '', // 显示名称
    bio: '', // 个人简介
    location: '', // 所在地
    website: '', // 个人网站
    birthDate: '', // 生日
    phone: '', // 手机号
    isVerified: 0, // 是否已验证
    isActive: 0, // 是否激活
    followersCount: 0, // 粉丝数
    followingCount: 0, // 关注数
    tweetsCount: 0, // 推文数
    likesCount: 0, // 点赞数
    createdAt: '', // 创建时间
    updatedAt: '', // 更新时间
    lastLoginAt: '', // 最后登录时间
    createdBy: '', // 创建人
    updatedBy: '' // 更新人
  }
};

// --- Store 定义 ---
export const usePreferenceStore = defineStore(
  'preferences',
  () => {
    // 1. 状态 (State):
    // 【修改点 1】: 为这个 Cookie 添加更安全的选项
    const preferences = useCookie<UserPreference>(
      'user-preferences-and-auth', // 建议改个名以反映其新职责
      {
        default: () => defaultPreferences,
        // 【新增】: 推荐为包含认证信息的 Cookie 添加这些选项
        maxAge: 30 * 24 * 60 * 60, // Cookie 的最长有效期（例如30天）
        sameSite: 'lax' // 防范 CSRF 攻击
        // secure: process.env.NODE_ENV === 'production', // 只在 HTTPS 下发送 (生产环境推荐)
        // httpOnly: false // 【注意】: 如果要从客户端JS访问，httpOnly必须为false。
        // 如果你后端也设置了 httpOnly cookie，那么这里就是它的 "影子"。
      }
    );

    // 2. 计算属性 (Getters):
    const isDarkModeActive = computed(() => {
      if (preferences.value.theme_mode === 'dark') {
        return true;
      }
      if (preferences.value.theme_mode === 'light') {
        return false;
      }
      // 对于 'system' 模式，这段逻辑只应该在客户端运行，
      // 因为服务器不知道用户的操作系统主题。
      if (process.client) {
        return window.matchMedia(
          '(prefers-color-scheme: dark)'
        ).matches;
      }
      return false; // 在服务器端，为 'system' 模式默认返回 false
    });

    // 【修改点 2】: 新增一个 Getter 用于方便地判断登录状态
    const isLoggedIn = computed(() => {
      // 只要 access_token 存在且不为空，我们就认为用户已登录。
      return !!preferences.value?.access_token;
    });

    // 3. 操作 (Actions):
    // 您的通用 updatePreference action 保持不变，它非常棒！
    function updatePreference<
      K extends keyof UserPreference
    >(key: K, value: UserPreference[K]) {
      if (preferences.value) {
        (preferences.value as any)[key] = value;
      }
    }

    // 【修改点 3】: 新增专门用于认证的 Actions
    /**
     * 在用户成功登录后调用此 Action。
     * @param newAccessToken 从 API 返回的 access token
     * @param newRefreshToken 从 API 返回的 refresh token
     */
    function setAuthTokens(
      newAccessToken: string,
      newRefreshToken: string
    ) {
      console.log('[PreferenceStore] Setting auth tokens.');
      // 使用已有的通用 action 来更新状态，这很优雅！
      updatePreference('access_token', newAccessToken);
      updatePreference('refresh_token', newRefreshToken);
    }

    /**
     * 在用户登出时调用此 Action。
     */
    function clearAuthTokens() {
      console.log(
        '[PreferenceStore] Clearing auth tokens.'
      );
      // 将令牌重置为初始的空字符串状态
      updatePreference('access_token', '');
      updatePreference('refresh_token', '');
    }

    // 您已有的其他 actions (setTheme, toggleCompactMode) 保持不变
    function setTheme(mode: ThemeMode) {
      updatePreference('theme_mode', mode);
    }
    function toggleCompactMode() {
      updatePreference(
        'compact_mode',
        !preferences.value.compact_mode
      );
    }
    /**
     * 将所有设置重置为默认值。
     * 【可选修改】: 登出时，可以选择完全重置，或只清除令牌。
     * 如果选择只清除令牌，这个函数保持原样。
     */
    function resetToDefaults() {
      preferences.value = defaultPreferences;
    }

    // 4. 返回: 暴露出新增的 getters 和 actions
    return {
      preferences,
      isDarkModeActive,
      isLoggedIn, // 【新增】
      updatePreference,
      setTheme,
      toggleCompactMode,
      resetToDefaults,
      setAuthTokens, // 【新增】
      clearAuthTokens // 【新增】
    };
  }
);
