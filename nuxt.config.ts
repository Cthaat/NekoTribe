// https://nuxt.com/docs/api/configuration/nuxt-config
import tailwindcss from '@tailwindcss/vite'

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
    '@nuxtjs/color-mode'
  ],

  css: ['~/assets/css/tailwind.css'],

  vite: {
    plugins: [
      tailwindcss(),
    ],
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

  nitro: {
    experimental: {
      websocket: true
    }
  },

  // 运行时配置，环境变量通过 process.env 传递
  runtimeConfig: {
    // JWT 密钥
    jwtSecret: process.env.JWT_SECRET,
    // JWT 过期时间
    jwtExpiresIn: process.env.JWT_EXPIRES_IN,
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
    public: {
      wsUrl: process.env.NUXT_PUBLIC_WS_URL || 'ws://localhost:3001'
    }
  },
})