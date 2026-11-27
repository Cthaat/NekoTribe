import { defineStore } from 'pinia';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
import { invalidAuthResponse } from '@/services/auth-response';
import { computed } from 'vue';
import type {
  UserPreference,
  ThemeMode,
  LanguageCode
} from './type';
import {
  v2RefreshCurrentToken,
  v2LogoutCurrent,
  type AuthSessionVM,
  type CurrentUserVM
} from '@/services';
import { normalizeAvatarUrl } from '@/utils/assets';

interface ClearAuthStateOptions {
  redirect?: boolean;
}

type LogoutResult = { revision: number; ok: true }
  | { revision: number; ok: false; error: unknown };

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
    onlineStatus: 'hidden',
    lastSeenAt: null,
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
  glass_intensity: 'standard',
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
    const authApp = useNuxtApp();
    const authQueue = authQueueFor(authApp);
    const authRevision = (): number => authQueue.revision;
    const isAuthCurrent = (revision: number): boolean => authRevision() === revision;
    // 1. 状态 (State):
    // 【修改点 1】: 为这个 Cookie 添加更安全的选项
    const preferences = useCookie<UserPreference>(
      'user-preferences-and-auth', // 建议改个名以反映其新职责
      {
        default: () => structuredClone(defaultPreferences),
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
      if (import.meta.client) {
        return window.matchMedia(
          '(prefers-color-scheme: dark)'
        ).matches;
      }
      return false;
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
    let refreshRevision = -1;
    // 标记是否正在刷新token
    const isRefreshingToken = ref(false);

    async function refreshAccessToken() {
      const revision = authRevision();
      const previousSessionId = preferences.value.authSession?.sessionId;
      // 如果已经有一个刷新请求在进行中，直接返回该Promise
      if (refreshPromise && refreshRevision === revision) {
        return refreshPromise;
      }
      isRefreshingToken.value = true;

      // 创建刷新Promise
      const pending: Promise<void> = (async () => {
        try {
          const session = await authApp.runWithContext(async () => v2RefreshCurrentToken());
          if (!isAuthCurrent(revision)) throw new Error('Authentication action superseded');
          if (previousSessionId !== undefined && session.sessionId !== previousSessionId) throw invalidAuthResponse();
          setCurrentSession(session);
        } catch (error) {
          if (isAuthCurrent(revision)) clearAuthState();
          throw error;
        }
      })().finally(() => {
        // 仅本次操作仍拥有缓存时清理，不能影响新会话的刷新。
        if (refreshPromise === pending) {
          refreshPromise = null;
          isRefreshingToken.value = false;
        }
      });
      refreshPromise = pending;
      refreshRevision = revision;
      return pending;
    }

    /**
     * 在用户登出时调用此 Action。
     */
    function clearAuthState(
      options: ClearAuthStateOptions = {}
    ) {
      authQueue.beginIdentityChange();
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
      authQueue.beginIdentityChange();
      const language = normalizeStoredLanguage(
        preferences.value.language
      );
      preferences.value = structuredClone(defaultPreferences);
      updatePreference('language', language);
    }

    async function logoutCurrentSession(expectedRevision = authRevision()): Promise<LogoutResult | null> {
      if (!isAuthCurrent(expectedRevision)) return null;
      const request = authApp.runWithContext(v2LogoutCurrent);
      const revision = authRevision();
      let outcome: { ok: true } | { ok: false; error: unknown } = { ok: true };
      try { await request; } catch (error) { outcome = { ok: false, error }; }
      if (!isAuthCurrent(revision)) return null;
      resetToDefaults();
      return { revision: authRevision(), ...outcome };
    }

    if (preferences.value.user.id === undefined) {
      preferences.value = structuredClone(defaultPreferences);
    }
    preferences.value.user = normalizeStoredUser(
      preferences.value.user
    );
    preferences.value.language = normalizeStoredLanguage(
      preferences.value.language
    );
    if (
      preferences.value.glass_intensity !== 'standard' &&
      preferences.value.glass_intensity !== 'subtle'
    ) {
      preferences.value.glass_intensity = 'standard';
    }

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
      authRevision,
      isAuthCurrent,
      logoutCurrentSession,
      setCurrentUser,
      setCurrentSession,
      refreshAccessToken,
      clearAuthState
    };
  }
);


