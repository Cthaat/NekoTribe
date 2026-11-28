// https://nuxt.com/docs/api/configuration/nuxt-config
import { fileURLToPath } from 'node:url';
import tailwindcss from '@tailwindcss/vite';
import publicTermsCatalog from './specifications/requirements/ai-public-terms-catalog.json';
import { parseTermsCatalog } from './server/services/ai/public-terms-source';

type ViteHmrProtocol = 'ws' | 'wss';

interface ViteHmrConfig {
  protocol?: ViteHmrProtocol;
  host?: string;
  clientPort?: number;
}

interface ViteServerConfig {
  hmr: ViteHmrConfig;
}

function devHmrProtocol(): ViteHmrProtocol | undefined {
  const protocol = process.env.NUXT_DEV_HMR_PROTOCOL;
  if (protocol === 'ws' || protocol === 'wss') {
    return protocol;
  }
  return undefined;
}

function devHmrClientPort(): number | undefined {
  const rawPort = process.env.NUXT_DEV_HMR_CLIENT_PORT;
  if (!rawPort) return undefined;

  const port = Number.parseInt(rawPort, 10);
  return Number.isInteger(port) && port > 0 ? port : undefined;
}

function devViteServerConfig(): ViteServerConfig | undefined {
  const hmr: ViteHmrConfig = {
    protocol: devHmrProtocol(),
    host: process.env.NUXT_DEV_HMR_HOST || undefined,
    clientPort: devHmrClientPort()
  };

  if (!hmr.protocol && !hmr.host && !hmr.clientPort) {
    return undefined;
  }

  return { hmr };
}

const viteServerConfig = devViteServerConfig();

export default defineNuxtConfig({
  appConfig: {
    publicTermsReferences: parseTermsCatalog(publicTermsCatalog).slice()
  },
  compatibilityDate: '2026-04-26',
  app: {
    pageTransition: { name: 'page', mode: 'out-in' }
  },
  debug: false,
  devtools: {
    enabled:
      process.env.NODE_ENV !== 'production' &&
      process.env.NUXT_DEVTOOLS !== 'false'
  },

  alias: {
    '~/server': fileURLToPath(
      new URL('./server', import.meta.url)
    ),
    '@/server': fileURLToPath(
      new URL('./server', import.meta.url)
    )
  },

  modules: [
    function debugPages(_options, nuxt) {
      if (nuxt.options.dev && process.env.NUXT_ENABLE_DEBUG_PAGES === '1') return;
      const debugFiles = new Set(['test.vue', 'test-token-refresh.vue', 'ws/index.vue']);
      nuxt.hook('pages:extend', pages => {
        for (let index = pages.length - 1; index >= 0; index--) {
          const name = pages[index]?.file?.replaceAll('\\', '/').split('/app/pages/').at(-1);
          if (name && debugFiles.has(name)) pages.splice(index, 1);
        }
      });
    },
    '@nuxt/eslint',
    '@nuxt/fonts',
    '@nuxt/icon',
    '@nuxt/image',
    '@nuxt/ui',
    'shadcn-nuxt',
    '@nuxtjs/color-mode',
    '@nuxtjs/i18n',
    '@pinia/nuxt'
  ],

  css: ['~/assets/css/tailwind.css', '~/assets/css/content-motion.css'],

  vite: {
    plugins: [tailwindcss()],
    ...(viteServerConfig ? { server: viteServerConfig } : {})
  },

  colorMode: {
    classSuffix: ''
  },

  shadcn: {
    /**
     * Prefix for all the imported component
     */
    prefix: '',
    /**
     * Directory that the component lives in.
     * @default "./components/ui"
     */
    componentDir: './app/components/ui'
  },

  typescript: {
    strict: true,
    // Typed API responses reference these legacy server declarations.
    tsConfig: {
      compilerOptions: { allowImportingTsExtensions: true },
      files: [
        '../server/type.d.ts',
        '../server/api/v1/analytics/type.d.ts',
        '../server/api/v1/auth/type.d.ts',
        '../server/api/v1/follow/type.d.ts',
        '../server/api/v1/hashtags/type.d.ts',
        '../server/api/v1/interactions/type.d.ts',
        '../server/api/v1/notifications/type.d.ts',
        '../server/api/v1/tweets/type.d.ts',
        '../server/api/v1/users/type.d.ts'
      ]
    }
  },

  i18n: {
    strategy: 'prefix',
    locales: [
      {
        code: 'en',
        name: 'English',
        language: 'en-US',
        file: 'en.json'
      },
      {
        code: 'zh',
        name: '简体中文',
        language: 'zh-CN',
        file: 'zh.json'
      }
    ],
    defaultLocale: 'zh',
    lazy: true,
    langDir: 'locales',
    detectBrowserLanguage: {
      useCookie: true,
      cookieKey: 'nekotribe_locale',
      redirectOn: 'root',
      fallbackLocale: 'zh'
    }
  },

  nitro: {
    debug: false,
    typescript: {
      tsConfig: { compilerOptions: { allowImportingTsExtensions: true } }
    },
    experimental: {
      websocket: true
    },
    prerender: {
      // 彻底禁用预渲染功能
      crawlLinks: false,
      routes: []
    }
  },

  // Defaults are portable; private deployment values are injected at runtime.
  // scripts/run-nuxt.mjs maps legacy .env keys to the matching NUXT_* keys.
  runtimeConfig: {
    apiServerBase: '',
    accessSecret: '',
    accessExpiresIn: '900',
    cookieSecure: false,
    refreshSecret: '',
    refreshExpiresIn: '2592000',
    nodeEnv: '',
    oracleHost: '',
    oraclePort: '',
    oracleSid: '',
    oracleServiceName: '',
    oracleUser: '',
    oraclePassword: '',
    oraclePoolMin: '2',
    oraclePoolMax: '10',
    oraclePoolIncrement: '1',
    redisUrl: '',
    redisHost: '',
    redisPort: '',
    redisDb: '',
    redisPassword: '',
    smtpHost: '',
    smtpPort: '',
    smtpUser: '',
    smtpPass: '',
    nlsLang: '',
    public: {
      wsUrl: '',
      apiBase: '',
      storageBase: ''
    }
  }
});
