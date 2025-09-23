// https://nuxt.com/docs/api/configuration/nuxt-config
import tailwindcss from '@tailwindcss/vite';

export default defineNuxtConfig({
  compatibilityDate: '2025-05-15',
  devtools: { enabled: true },

  modules: [
    '@nuxt/content',
    '@nuxt/eslint',
    '@nuxt/fonts',
    '@nuxt/icon',
    '@nuxt/image',
    '@nuxt/ui',
    'shadcn-nuxt',
    '@nuxtjs/color-mode',
    '@nuxtjs/i18n',
    '@pinia/nuxt',
    'vue-sonner/nuxt'
  ],

  css: ['~/assets/css/tailwind.css'],

  vite: {
    plugins: [tailwindcss()]
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
    componentDir: './components/ui'
  },

  i18n: {
    locales: [
      { code: 'en', name: 'English', file: 'en.json' },
      { code: 'cn', name: 'Chinese', file: 'cn.json' }
    ],
    defaultLocale: 'en', // 默认语言
    lazy: true, // 推荐开启懒加载
    langDir: 'locales' // 语言文件目录
  },

  nitro: {
    experimental: {
      websocket: true
    },
    prerender: {
      // 彻底禁用预渲染功能
      crawlLinks: false,
      routes: []
    },
    hooks: {
      // 在 Nitro 实例关闭时，执行此函数
      close: () => {
        // 当这个钩子被触发时，我们知道所有构建工作都已完成
        console.log(
          'Nuxt build process complete. Forcing exit to release OracleDB handles...'
        );

        // 我们不直接退出，而是设置一个短暂的延时
        // 这给日志信息完全刷新到控制台留出了一点时间
        setTimeout(() => {
          // 传递 0 表示“成功退出”
          process.exit(0);
        }, 500); // 500毫秒的延迟
      }
    }
  },

  // 运行时配置，环境变量通过 process.env 传递
  runtimeConfig: {
    // 访问令牌密钥
    accessSecret: process.env.ACCESS_SECRET,
    // 访问令牌过期时间
    accessExpiresIn: process.env.ACCESS_EXPIRES_IN,
    // 刷新令牌密钥
    refreshSecret: process.env.REFRESH_SECRET,
    // 刷新令牌过期时间
    refreshExpiresIn: process.env.REFRESH_EXPIRES_IN,
    // 当前运行环境
    nodeEnv: process.env.NODE_ENV,
    // Oracle 数据库主机
    oracleHost: process.env.ORACLE_HOST,
    // Oracle 数据库端口
    oraclePort: process.env.ORACLE_PORT,
    // Oracle SID
    oracleSid: process.env.ORACLE_SID,
    // Oracle 服务名
    oracleServiceName: process.env.ORACLE_SERVICE_NAME,
    // Oracle 用户名
    oracleUser: process.env.ORACLE_USER,
    // Oracle 密码
    oraclePassword: process.env.ORACLE_PASSWORD,
    // Oracle 连接池配置
    oraclePoolMin: process.env.ORACLE_POOL_MIN,
    oraclePoolMax: process.env.ORACLE_POOL_MAX,
    oraclePoolIncrement: process.env.ORACLE_POOL_INCREMENT,
    // Redis 连接信息
    redisUrl: process.env.REDIS_URL,
    redisHost: process.env.REDIS_HOST,
    redisPort: process.env.REDIS_PORT,
    redisDb: process.env.REDIS_DB,
    redisPassword: process.env.REDIS_PASSWORD,
    // 邮箱连接
    smtpHost: process.env.SMTP_HOST,
    smtpPort: process.env.SMTP_PORT,
    smtpUser: process.env.SMTP_USER,
    smtpPass: process.env.SMTP_PASS,
    public: {
      wsUrl:
        process.env.NUXT_PUBLIC_WS_URL ||
        'ws://localhost:3001',
      apiBase: process.env.NUXT_PUBLIC_API_BASE || ''
    }
  }
});
