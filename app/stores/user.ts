import { defineStore } from 'pinia';
import { computed } from 'vue';
import type {
  UserPreference,
  ThemeMode,
  LanguageCode
} from './type';
import {
  v2RefreshCurrentToken,
  type AuthSessionVM,
  type CurrentUserVM
} from '@/services';
import { normalizeAvatarUrl } from '@/utils/assets';

interface ClearAuthStateOptions {
  redirect?: boolean;
}

function createEmptyUser(): CurrentUserVM {
  return {
    id: 0,
    email: '',
    username: '',
    avatarUrl: '',
    name: '',
    bio: '',
    location: '',
    website: '',
    phone: '',
    birthDate: null,
    emailVerifiedAt: null,
    verified: false,
    active: false,
    status: '',
    followersCount: 0,
    followingCount: 0,
    postsCount: 0,
    likesCount: 0,
    createdAt: '',
    updatedAt: '',
    relationship: {
      isSelf: true,
      isFollowing: false,
      isBlocked: false,
      isBlocking: false,
      relation: 'self'
    }
  };
}

function normalizeStoredUser(
  user: CurrentUserVM
): CurrentUserVM {
  if (!user.id) {
    return user;
  }

  return {
    ...user,
    avatarUrl: normalizeAvatarUrl(user.avatarUrl)
  };
}

function normalizeStoredLanguage(
  language: string | undefined
): LanguageCode {
  if (
    language === 'zh' ||
    language === 'cn' ||
    language?.startsWith('zh')
  ) {
    return 'zh';
  }

  if (language === 'en' || language?.startsWith('en')) {
    return 'en';
  }

  return 'zh';
}

// --- 默认状态 ---
// 这个对象保持不变，它定义了所有用户偏好的初始值。
const defaultPreferences: UserPreference = {
  // 主题相关
  theme_mode: 'system',
  font_size: 'normal',
  language: 'zh',
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
  user: createEmptyUser(),
  authSession: null
};

function resolveLoginPath(): string {
  try {
    const localePath = useLocalePath();
    return localePath('/auth/login');
  } catch {
    return '/auth/login';
  }
}

function redirectToLogin(): void {
  if (!import.meta.client) {
    return;
  }

  const loginPath = resolveLoginPath();
  try {
    const router = useRouter();
    void router.push(loginPath);
    return;
  } catch {
    if (window.location.pathname !== loginPath) {
      window.location.assign(loginPath);
    }
  }
}

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
      return preferences.value.user.id > 0;
    });

    // 3. 操作 (Actions):
    // 您的通用 updatePreference action 保持不变，它非常棒！
    function updatePreference<
      K extends keyof UserPreference
    >(key: K, value: UserPreference[K]) {
      if (preferences.value) {
        preferences.value[key] = value;
      }
    }

    function setCurrentUser(user: CurrentUserVM) {
      updatePreference('user', normalizeStoredUser(user));
    }

    function setCurrentSession(
      session: AuthSessionVM | null
    ) {
      updatePreference('authSession', session);
    }

    // 用于防止重复刷新的Promise缓存
    let refreshPromise: Promise<void> | null = null;
    // 标记是否正在刷新token
    const isRefreshingToken = ref(false);

    async function refreshAccessToken() {
      // 如果已经有一个刷新请求在进行中，直接返回该Promise
      if (refreshPromise) {
        return refreshPromise;
      }
      isRefreshingToken.value = true;

      // 创建刷新Promise
      refreshPromise = (async () => {
        try {
          const session = await v2RefreshCurrentToken();
          setCurrentSession(session);
        } catch (error) {
          console.error(
            '[PreferenceStore] Token刷新失败:',
            error
          );
          clearAuthState();
          throw error;
        } finally {
          // 清除Promise缓存，允许下次刷新
          refreshPromise = null;
          isRefreshingToken.value = false;
        }
      })();

      return refreshPromise;
    }

    /**
     * 在用户登出时调用此 Action。
     */
    function clearAuthState(
      options: ClearAuthStateOptions = {}
    ) {
      updatePreference('user', createEmptyUser());
      updatePreference('authSession', null);
      if (options.redirect ?? true) {
        redirectToLogin();
      }
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
      const language = normalizeStoredLanguage(
        preferences.value.language
      );
      preferences.value = defaultPreferences;
      updatePreference('language', language);
    }

    if (preferences.value.user.id === undefined) {
      preferences.value = defaultPreferences;
    }
    preferences.value.user = normalizeStoredUser(
      preferences.value.user
    );
    preferences.value.language = normalizeStoredLanguage(
      preferences.value.language
    );

    // 4. 返回: 暴露出新增的 getters 和 actions
    return {
      preferences,
      isDarkModeActive,
      isLoggedIn, // 【新增】
      isRefreshingToken, // 【新增】暴露刷新状态
      updatePreference,
      setTheme,
      toggleCompactMode,
      resetToDefaults,
      setCurrentUser,
      setCurrentSession,
      refreshAccessToken,
      clearAuthState
    };
  }
);


