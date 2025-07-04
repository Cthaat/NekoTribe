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

  // 运行时配置，环境变量通过 process.env 传递
  runtimeConfig: {
    // JWT 密钥
    jwtSecret: process.env.JWT_SECRET,
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
    // 只在服务器端可用的私有 key
    redisUrl: process.env.REDIS_URL,

    public: {
      wsUrl: process.env.NUXT_PUBLIC_WS_URL || 'ws://localhost:3000'
    }
  },
})