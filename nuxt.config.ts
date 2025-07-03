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

    runtimeConfig: {
    jwtSecret: process.env.JWT_SECRET,
    
    // Oracle 数据库配置（保留用于迁移）
    oracleHost: process.env.ORACLE_HOST,
    oraclePort: process.env.ORACLE_PORT,
    oracleSid: process.env.ORACLE_SID,
    oracleServiceName: process.env.ORACLE_SERVICE_NAME,
    oracleUser: process.env.ORACLE_USER,
    oraclePassword: process.env.ORACLE_PASSWORD,
    oraclePoolMin: process.env.ORACLE_POOL_MIN,
    oraclePoolMax: process.env.ORACLE_POOL_MAX,
    oraclePoolIncrement: process.env.ORACLE_POOL_INCREMENT,
    
    // OceanBase 数据库配置
    oceanbaseHost: process.env.OCEANBASE_HOST,
    oceanbasePort: process.env.OCEANBASE_PORT,
    oceanbaseUser: process.env.OCEANBASE_USER,
    oceanbasePassword: process.env.OCEANBASE_PASSWORD,
    oceanbaseDatabase: process.env.OCEANBASE_DATABASE,
  },
})