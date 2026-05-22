import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync
} from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

const repoRoot = new URL('..', import.meta.url).pathname.replace(
  /^\/([A-Za-z]:\/)/,
  '$1'
);

const staticExpectations = [
  {
    file: 'app/assets/css/tailwind.css',
    tokens: [
      'html,',
      'overflow-x: clip',
      '.mobile-scroll-safe',
      '.mobile-action-row'
    ]
  },
  {
    file: 'app/layouts/default.vue',
    tokens: [
      'min-h-dvh',
      'overflow-x-clip',
      'min-w-0 flex-1',
      '<main class="min-w-0 flex-1'
    ]
  },
  {
    file: 'app/layouts/chat.vue',
    tokens: ['overflow-x-clip', 'min-w-0']
  },
  {
    file: 'app/pages/chat.vue',
    tokens: [
      'data-chat-nav-panel="true"',
      'data-chat-content-panel="true"',
      'h-full w-full min-w-0 flex-shrink-0',
      "isMobileNavigationOpen ? 'flex' : 'hidden md:flex'",
      "isMobileNavigationOpen ? 'hidden md:block' : 'block'",
      'h-64 shrink-0',
      'max-md:h-[30dvh]',
      'max-md:min-h-44',
      'max-md:max-h-72'
    ],
    forbiddenTokens: [
      'class="h-[38dvh]',
      'class="h-[16dvh]',
      'max-md:h-[38dvh]',
      'max-md:h-[16dvh]'
    ]
  },
  {
    file: 'app/components/ui/dialog/DialogContent.vue',
    tokens: ['max-w-[calc(100vw-1rem)]', 'overscroll-contain']
  },
  {
    file: 'app/components/ui/dialog/DialogScrollContent.vue',
    tokens: ['max-w-[calc(100vw-1rem)]', 'overscroll-contain']
  },
  {
    file: 'app/components/ui/sheet/SheetContent.vue',
    tokens: ['max-w-full', 'overflow-y-auto', 'overscroll-contain']
  }
];

const defaultRoutes = [
  '/zh/auth/login',
  '/zh/auth/sign-up',
  '/zh/auth/forgot-password',
  '/zh/auth/terms'
];

const mockPreferenceCookie = {
  theme_mode: 'system',
  font_size: 'normal',
  language: 'zh',
  show_online_status: true,
  allow_dm_from_strangers: true,
  profile_visibility: 'public',
  push_notification_enabled: true,
  email_notification_enabled: true,
  notify_like: true,
  notify_comment: true,
  notify_follow: true,
  notify_mention: true,
  auto_play_video: true,
  show_sensitive_content: false,
  compact_mode: false,
  default_home_tab: 'timeline',
  badge_display: true,
  mute_keywords: [],
  blocked_users: [],
  user: {
    id: 1,
    email: 'mobile-preview@example.test',
    username: 'mobile_preview',
    avatarUrl: '',
    name: 'Mobile Preview',
    bio: '',
    location: '',
    website: '',
    phone: '',
    birthDate: null,
    emailVerifiedAt: null,
    verified: true,
    active: true,
    status: '',
    followersCount: 0,
    followingCount: 0,
    postsCount: 0,
    likesCount: 0,
    onlineStatus: 'online',
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
  },
  authSession: null
};

const defaultViewports = [
  [375, 812],
  [390, 844],
  [430, 932]
];

const desktopViewports = [
  [1280, 720],
  [1440, 900]
];

function hasFlag(name) {
  return process.argv.includes(name);
}

function valueAfter(name, fallback) {
  const index = process.argv.indexOf(name);
  return index === -1 ? fallback : process.argv[index + 1] ?? fallback;
}

function runStaticChecks() {
  const failures = [];

  for (const expectation of staticExpectations) {
    const filePath = join(repoRoot, expectation.file);
    const content = readFileSync(filePath, 'utf8');
    for (const token of expectation.tokens) {
      if (!content.includes(token)) {
        failures.push(`${expectation.file} is missing "${token}"`);
      }
    }
    for (const token of expectation.forbiddenTokens ?? []) {
      if (content.includes(token)) {
        failures.push(`${expectation.file} still includes "${token}"`);
      }
    }
  }

  if (failures.length > 0) {
    console.error('Mobile responsive static checks failed:');
    for (const failure of failures) {
      console.error(`- ${failure}`);
    }
    process.exitCode = 1;
    return;
  }

  console.log('Mobile responsive static checks passed.');
}

function chromePath() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
  ].filter(Boolean);

  const found = candidates.find(candidate => existsSync(candidate));
  if (!found) {
    throw new Error(
      'Chrome or Edge executable was not found. Set CHROME_PATH to run browser checks.'
    );
  }
  return found;
}

async function waitForDebuggingPort(port, timeoutMs = 8000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) return;
    } catch {
      await new Promise(resolve => setTimeout(resolve, 150));
    }
  }
  throw new Error(`Chrome remote debugging port ${port} did not become ready.`);
}

function connect(wsUrl) {
  const socket = new WebSocket(wsUrl);
  let id = 0;
  const pending = new Map();

  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) {
      reject(new Error(JSON.stringify(message.error)));
      return;
    }
    resolve(message.result);
  };

  return new Promise((resolve, reject) => {
    socket.onopen = () => {
      resolve({
        send(method, params = {}) {
          const requestId = ++id;
          socket.send(
            JSON.stringify({ id: requestId, method, params })
          );
          return new Promise((resolve, reject) => {
            pending.set(requestId, { resolve, reject });
          });
        },
        close() {
          socket.close();
        }
      });
    };
    socket.onerror = reject;
  });
}

async function evaluateWithRetry(cdp, params, attempts = 6) {
  let lastError;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return await cdp.send('Runtime.evaluate', params);
    } catch (error) {
      lastError = error;
      if (
        !String(error?.message || error).includes(
          'Cannot find default execution context'
        )
      ) {
        throw error;
      }
      await new Promise(resolve => setTimeout(resolve, 500));
    }
  }
  throw lastError;
}

async function openTab(port, url) {
  const response = await fetch(
    `http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`,
    { method: 'PUT' }
  );
  if (!response.ok) {
    throw new Error(`Failed to open ${url}: ${response.status}`);
  }
  return response.json();
}

async function createCdpPage(
  port,
  viewport = defaultViewports[0],
  emulateMobile = true
) {
  const target = await openTab(port, 'about:blank');
  const cdp = await connect(target.webSocketDebuggerUrl);
  const [width, height] = viewport;
  await cdp.send('Page.enable');
  await cdp.send('Network.enable');
  await cdp.send('Network.setBlockedURLs', {
    urls: ['*://*/_ws*', 'ws://*/_ws*', 'wss://*/_ws*']
  });
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `(() => {
      window.__NEKOTRIBE_DISABLE_REALTIME__ = true;
      class BlockedWebSocket {
        static CONNECTING = 0;
        static OPEN = 1;
        static CLOSING = 2;
        static CLOSED = 3;
        CONNECTING = 0;
        OPEN = 1;
        CLOSING = 2;
        CLOSED = 3;
        readyState = 3;
        bufferedAmount = 0;
        extensions = '';
        protocol = '';
        binaryType = 'blob';
        onopen = null;
        onmessage = null;
        onerror = null;
        onclose = null;
        constructor(url) {
          this.url = String(url || '');
          setTimeout(() => {
            this.onclose?.({ code: 1000, reason: 'blocked in mobile responsive check', wasClean: true });
          }, 0);
        }
        addEventListener(type, listener) {
          if (type === 'close') {
            setTimeout(() => listener({ code: 1000, reason: 'blocked in mobile responsive check', wasClean: true }), 0);
          }
        }
        removeEventListener() {}
        dispatchEvent() { return true; }
        close() {}
        send() {}
      }
      window.WebSocket = BlockedWebSocket;
    })();`
  });
  await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 2,
    mobile: emulateMobile
  });
  await cdp.send('Emulation.setUserAgentOverride', {
    userAgent: emulateMobile
      ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
      : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
  });
  return cdp;
}

function mapLoginUserForCookie(dto) {
  return {
    id: dto.user_id,
    email: dto.email,
    username: dto.username,
    avatarUrl: dto.avatar_url || '',
    name: dto.display_name,
    bio: dto.bio,
    location: dto.location,
    website: dto.website,
    phone: dto.phone,
    birthDate: dto.birth_date,
    emailVerifiedAt: dto.email_verified_at,
    verified: dto.is_verified === 1,
    active: dto.is_active === 1,
    status: dto.status,
    followersCount: dto.followers_count,
    followingCount: dto.following_count,
    postsCount: dto.posts_count,
    likesCount: dto.likes_count,
    onlineStatus: dto.online_status,
    lastSeenAt: dto.last_seen_at,
    createdAt: dto.created_at,
    updatedAt: dto.updated_at,
    relationship: {
      isSelf: dto.relationship?.is_self ?? true,
      isFollowing: dto.relationship?.is_following ?? false,
      isBlocked: dto.relationship?.is_blocked ?? false,
      isBlocking: dto.relationship?.is_blocking ?? false,
      relation: dto.relationship?.relation ?? 'self'
    }
  };
}

function splitSetCookie(header) {
  if (!header) return [];
  return header.split(/,(?=\s*[^;,=\s]+=[^;,]*)/g);
}

function parseSetCookie(setCookie) {
  const [pair = '', ...attributes] = setCookie.split(';');
  const equalsIndex = pair.indexOf('=');
  if (equalsIndex === -1) return null;
  const cookie = {
    name: pair.slice(0, equalsIndex).trim(),
    value: pair.slice(equalsIndex + 1).trim(),
    path: '/',
    sameSite: 'Lax',
    httpOnly: false,
    secure: false
  };

  for (const attribute of attributes) {
    const [rawKey, rawValue = ''] = attribute.trim().split('=');
    const key = rawKey.toLowerCase();
    if (key === 'path') cookie.path = rawValue || '/';
    if (key === 'httponly') cookie.httpOnly = true;
    if (key === 'secure') cookie.secure = true;
    if (key === 'samesite') {
      const value = rawValue.toLowerCase();
      cookie.sameSite =
        value === 'strict' ? 'Strict' : value === 'none' ? 'None' : 'Lax';
    }
  }

  return cookie.name ? cookie : null;
}

async function performApiLogin(baseUrl) {
  const account = process.env.NEKOTRIBE_TEST_ACCOUNT;
  const password = process.env.NEKOTRIBE_TEST_PASSWORD;
  if (!account || !password) {
    throw new Error(
      'Set NEKOTRIBE_TEST_ACCOUNT and NEKOTRIBE_TEST_PASSWORD before using --login.'
    );
  }

  const loginUrl = `${baseUrl.replace(/\/$/, '')}/api/v2/auth/tokens`;
  const response = await fetch(loginUrl, {
    method: 'POST',
    headers: {
      'content-type': 'application/json'
    },
    body: JSON.stringify({
      account,
      password,
      remember_me: true
    })
  });
  const payload = await response.json().catch(() => null);
  const isApiSuccess =
    response.ok &&
    payload?.data &&
    (payload.code === undefined || Number(payload.code) < 400);
  if (!isApiSuccess) {
    throw new Error(
      `API login failed with status ${response.status}: ${payload?.message || 'unknown error'}`
    );
  }
  if (payload.data.two_factor_required) {
    throw new Error('API login requires two-factor verification.');
  }

  const setCookies =
    typeof response.headers.getSetCookie === 'function'
      ? response.headers.getSetCookie()
      : splitSetCookie(response.headers.get('set-cookie'));
  const cookies = setCookies
    .map(parseSetCookie)
    .filter(Boolean);
  const preferenceCookie = {
    ...mockPreferenceCookie,
    user: mapLoginUserForCookie(payload.data.user),
    authSession: {
      sessionId: payload.data.tokens.session_id,
      accessTokenExpiresAt: payload.data.tokens.access_token_expires_at,
      refreshTokenExpiresAt: payload.data.tokens.refresh_token_expires_at
    }
  };

  return { cookies, preferenceCookie };
}

async function applyAuthState(cdp, baseUrl, authState, useMockAuth) {
  const url = baseUrl.replace(/\/$/, '');

  if (authState) {
    for (const cookie of authState.cookies) {
      await cdp.send('Network.setCookie', {
        name: cookie.name,
        value: cookie.value,
        url,
        path: cookie.path,
        sameSite: cookie.sameSite,
        httpOnly: cookie.httpOnly,
        secure: cookie.secure
      });
    }
  }

  const preferenceCookie =
    authState?.preferenceCookie ?? (useMockAuth ? mockPreferenceCookie : null);

  if (preferenceCookie) {
    await cdp.send('Network.setCookie', {
      name: 'user-preferences-and-auth',
      value: encodeURIComponent(JSON.stringify(preferenceCookie)),
      url,
      path: '/',
      sameSite: 'Lax'
    });
  }
}

function safeScreenshotName(route, width, height) {
  const cleanRoute = route
    .replace(/^\/+/, '')
    .replace(/[^A-Za-z0-9_-]+/g, '-')
    .replace(/^-|-$/g, '');
  return `${cleanRoute || 'root'}-${width}x${height}.png`;
}

async function runBrowserChecks() {
  const baseUrl = valueAfter('--url', 'http://[::1]:3000');
  const routes = valueAfter('--routes', defaultRoutes.join(','))
    .split(',')
    .map(route => route.trim())
    .filter(Boolean);
  const port = Number(valueAfter('--debug-port', '9331'));
  const screenshotDir = valueAfter('--screenshot-dir', '');
  const useMockAuth = hasFlag('--mock-auth');
  const useLogin = hasFlag('--login');
  const emulateMobile = !hasFlag('--desktop');
  const viewports = emulateMobile ? defaultViewports : desktopViewports;
  const openFirstChatChannel = hasFlag('--chat-open-first-channel');
  if (screenshotDir) {
    mkdirSync(screenshotDir, { recursive: true });
  }
  const userDataDir = join(
    tmpdir(),
    `nekotribe-mobile-responsive-${Date.now()}`
  );
  mkdirSync(userDataDir, { recursive: true });

  const browser = spawn(chromePath(), [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userDataDir}`,
    'about:blank'
  ], {
    stdio: 'ignore',
    windowsHide: true
  });

  const failures = [];
  try {
    await waitForDebuggingPort(port);
    const authState = useLogin ? await performApiLogin(baseUrl) : null;
    if (useLogin) {
      const hasAccessCookie = authState.cookies.some(
        cookie => cookie.name === 'access_token'
      );
      if (!hasAccessCookie) {
        throw new Error('API login did not return an access_token cookie.');
      }
    }

    for (const [width, height] of viewports) {
      for (const route of routes) {
        const cdp = await createCdpPage(port, [width, height], emulateMobile);
        const url = `${baseUrl.replace(/\/$/, '')}${route}`;

        try {
          await applyAuthState(cdp, baseUrl, authState, useMockAuth);
          await cdp.send('Page.navigate', { url });
          await new Promise(resolve => setTimeout(resolve, 2500));

          if (openFirstChatChannel && route.endsWith('/chat')) {
            await evaluateWithRetry(cdp, {
              returnByValue: true,
              expression: `(() => {
                const button = document.querySelector('[data-chat-channel-button="true"]');
                if (!(button instanceof HTMLElement)) return false;
                button.click();
                return true;
              })()`
            });
            await new Promise(resolve => setTimeout(resolve, 1000));
          }

          const result = await evaluateWithRetry(cdp, {
            returnByValue: true,
            expression: `(() => {
              const doc = document.documentElement;
              const body = document.body;
              const vw = doc.clientWidth;
              const isInsideHorizontalBoundary = (el) => {
                let parent = el.parentElement;
                while (parent && parent !== body && parent !== doc) {
                  const style = getComputedStyle(parent);
                  if (['auto', 'scroll', 'hidden', 'clip'].includes(style.overflowX)) {
                    const rect = parent.getBoundingClientRect();
                    return rect.left >= -1 && rect.right <= vw + 1;
                  }
                  parent = parent.parentElement;
                }
                return false;
              };
              const overflowers = [...document.querySelectorAll('body *')]
                .map((el) => {
                  const rect = el.getBoundingClientRect();
                  return {
                    el,
                    tag: el.tagName.toLowerCase(),
                    className: String(el.className || '').slice(0, 140),
                    text: (el.innerText || '').replace(/\\s+/g, ' ').slice(0, 80),
                    left: Math.round(rect.left),
                    right: Math.round(rect.right),
                    width: Math.round(rect.width)
                  };
                })
                .filter(item => item.right > vw + 1 || item.left < -1)
                .filter(item => !['circle', 'line', 'path', 'polyline', 'rect'].includes(item.tag))
                .filter(item => !item.className.includes('toaster'))
                .filter((item) => {
                  return !isInsideHorizontalBoundary(item.el);
                })
                .map(({ el, ...item }) => item)
                .slice(0, 8);
              const isChatRoute = location.pathname.endsWith('/chat');
              const chatNavigationPanel = isChatRoute
                ? document.querySelector('[data-chat-nav-panel="true"]')
                : null;
              const chatContentPanel = isChatRoute
                ? document.querySelector('[data-chat-content-panel="true"]')
                : null;
              const chatNavigationRect =
                chatNavigationPanel?.getBoundingClientRect() ?? null;
              const chatContentRect =
                chatContentPanel?.getBoundingClientRect() ?? null;
              const isPanelVisible = (el, rect) => {
                if (!el || !rect) return false;
                const style = getComputedStyle(el);
                return style.display !== 'none' &&
                  style.visibility !== 'hidden' &&
                  rect.width > 1 &&
                  rect.height > 1;
              };
              const chatNavigationVisible =
                isPanelVisible(chatNavigationPanel, chatNavigationRect);
              const chatContentVisible =
                isPanelVisible(chatContentPanel, chatContentRect);
              const chatNavigationMinHeight = vw >= 768
                ? Math.max(0, doc.clientHeight - 80)
                : 0;
              const chatNavigationTooShort =
                isChatRoute &&
                vw >= 768 &&
                (!chatNavigationRect ||
                  chatNavigationRect.height < chatNavigationMinHeight);
              const chatMobilePanelsStacked =
                isChatRoute &&
                vw < 768 &&
                chatNavigationVisible &&
                chatContentVisible;
              return {
                href: location.href,
                title: document.title,
                bodyText: document.body?.innerText?.slice(0, 240) || '',
                viewport: [vw, doc.clientHeight],
                documentScrollWidth: doc.scrollWidth,
                bodyScrollWidth: body ? body.scrollWidth : 0,
                chatNavigationHeight: chatNavigationRect
                  ? Math.round(chatNavigationRect.height)
                  : null,
                chatContentHeight: chatContentRect
                  ? Math.round(chatContentRect.height)
                  : null,
                chatNavigationMinHeight,
                chatNavigationTooShort,
                chatNavigationVisible,
                chatContentVisible,
                chatMobilePanelsStacked,
                overflowers
              };
            })()`
          });

          const value = result.result.value;
          const scrollWidth = Math.max(
            value.documentScrollWidth,
            value.bodyScrollWidth
          );
          const isBrowserErrorPage =
            value.href.startsWith('chrome-error://') ||
            value.title.includes('无法访问') ||
            value.title.includes('This site') ||
            value.bodyText.includes('ERR_CONNECTION_REFUSED') ||
            value.bodyText.includes('拒绝了我们的连接请求');
          if (
            isBrowserErrorPage ||
            scrollWidth > value.viewport[0] ||
            value.overflowers.length > 0 ||
            value.chatNavigationTooShort ||
            value.chatMobilePanelsStacked
          ) {
            failures.push({
              route,
              viewport: `${width}x${height}`,
              href: value.href,
              title: value.title,
              browserError: isBrowserErrorPage,
              scrollWidth,
              clientWidth: value.viewport[0],
              chatNavigationHeight: value.chatNavigationHeight,
              chatContentHeight: value.chatContentHeight,
              chatNavigationMinHeight: value.chatNavigationMinHeight,
              chatNavigationTooShort: value.chatNavigationTooShort,
              chatNavigationVisible: value.chatNavigationVisible,
              chatContentVisible: value.chatContentVisible,
              chatMobilePanelsStacked: value.chatMobilePanelsStacked,
              overflowers: value.overflowers
            });
          }

          if (screenshotDir) {
            const screenshot = await cdp.send('Page.captureScreenshot', {
              format: 'png',
              captureBeyondViewport: false
            });
            writeFileSync(
              join(screenshotDir, safeScreenshotName(route, width, height)),
              Buffer.from(screenshot.data, 'base64')
            );
          }
        } finally {
          cdp.close();
        }
      }
    }
  } finally {
    browser.kill();
  }

  if (failures.length > 0) {
    console.error('Mobile responsive browser checks failed:');
    console.error(JSON.stringify(failures, null, 2));
    process.exitCode = 1;
    return;
  }

  console.log(
    `Mobile responsive browser checks passed for ${routes.length} routes.`
  );
}

if (hasFlag('--browser')) {
  await runBrowserChecks();
} else {
  runStaticChecks();
}
