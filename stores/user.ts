// stores/preferenceStore.ts

import { defineStore } from 'pinia';
import { computed } from 'vue';
// 从我们第一步创建的文件中导入你的类型
import type { UserPreference, ThemeMode } from './type';
// --- 默认状态 ---
// 定义一个新用户或重置设置时的默认偏好。
// 这是一个完全符合 UserPreference 接口的普通对象。
const defaultPreferences: UserPreference = {
  // 1. 主题相关
  theme_mode: 'system',
  font_size: 'normal',
  language: 'en',

  // 2. 隐私和安全
  show_online_status: true,
  allow_dm_from_strangers: false,
  profile_visibility: 'public',

  // 3. 通知设置
  push_notification_enabled: true,
  email_notification_enabled: true,
  notify_like: true,
  notify_comment: true,
  notify_follow: true,
  notify_mention: true,

  // 4. 功能开关
  auto_play_video: true,
  show_sensitive_content: false,
  compact_mode: false,

  // 5. 个性化体验
  default_home_tab: 'timeline',
  badge_display: true,

  // 6. 可选的数组应初始化为空数组，以避免 undefined 问题
  mute_keywords: [],
  blocked_users: []
};

// --- Store 定义 ---
// 使用 defineStore 创建 store，'preferences' 是这个 store 的唯一 ID。
export const usePreferenceStore = defineStore(
  'preferences',
  () => {
    // 1. 状态 (State): Store 的核心
    // 我们使用 `useCookie` 来创建一个响应式的、且 SSR 安全的 Cookie。
    // 'user-preferences' 是将保存在浏览器中的 Cookie 的名字。
    // 每当 state 变化时，这个 Cookie 会被自动更新。
    const preferences = useCookie<UserPreference>(
      'user-preferences',
      {
        // `default` 选项提供了当 Cookie 不存在时的初始值。
        // 将其包装在函数 `() => ...` 中是保证 SSR 安全的最佳实践。
        default: () => defaultPreferences
      }
    );

    // 2. 计算属性 (Getters): 从 state 派生的值
    // 这对于处理复杂逻辑很有用。例如，根据系统设置决定最终的主题。
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

    // 3. 操作 (Actions): 修改 state 的函数

    /**
     * 一个通用的、类型安全的 Action，用于更新任何单个偏好。
     * 这非常高效，可以避免为每个属性都编写一个独立的 action。
     * @param key 要更新的偏好键 (例如 'theme_mode')
     * @param value 新的值 (例如 'dark')
     */
    function updatePreference<
      K extends keyof UserPreference
    >(key: K, value: UserPreference[K]) {
      // 因为 `preferences` 是 useCookie 返回的一个 Ref，我们必须修改它的 .value 属性。
      if (preferences.value) {
        // 使用 `as any` 是因为 TypeScript 在这里难以推断动态键值的类型，但我们通过泛型保证了外部调用的安全。
        (preferences.value as any)[key] = value;
      }
    }

    /**
     * 一个更具体的、对开发者友好的 Action，用于常见任务。
     * @param mode 新的主题模式 ('dark', 'light', 或 'system')
     */
    function setTheme(mode: ThemeMode) {
      updatePreference('theme_mode', mode);
    }

    /**
     * 一个用于切换布尔值偏好的 Action 示例。
     */
    function toggleCompactMode() {
      updatePreference(
        'compact_mode',
        !preferences.value.compact_mode
      );
    }

    /**
     * 将所有设置重置为默认值。
     */
    function resetToDefaults() {
      preferences.value = defaultPreferences;
    }

    // 4. 返回: 暴露出需要给组件使用的 state, getters 和 actions
    return {
      preferences, // 主状态对象 (它是一个 Ref)
      isDarkModeActive, // 一个计算属性 getter
      updatePreference, // 通用的 action
      setTheme, // 特定的 action
      toggleCompactMode,
      resetToDefaults
    };
  }
);
