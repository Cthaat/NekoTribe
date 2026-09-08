// Keep legacy .env names usable when a previously built server is moved.
export const runtimeAliases = {
  ACCESS_SECRET: 'NUXT_ACCESS_SECRET',
  ACCESS_EXPIRES_IN: 'NUXT_ACCESS_EXPIRES_IN',
  REFRESH_SECRET: 'NUXT_REFRESH_SECRET',
  REFRESH_EXPIRES_IN: 'NUXT_REFRESH_EXPIRES_IN',
  COOKIE_SECURE: 'NUXT_COOKIE_SECURE',
  ORACLE_HOST: 'NUXT_ORACLE_HOST',
  ORACLE_PORT: 'NUXT_ORACLE_PORT',
  ORACLE_SID: 'NUXT_ORACLE_SID',
  ORACLE_SERVICE_NAME: 'NUXT_ORACLE_SERVICE_NAME',
  ORACLE_USER: 'NUXT_ORACLE_USER',
  ORACLE_PASSWORD: 'NUXT_ORACLE_PASSWORD',
  ORACLE_POOL_MIN: 'NUXT_ORACLE_POOL_MIN',
  ORACLE_POOL_MAX: 'NUXT_ORACLE_POOL_MAX',
  ORACLE_POOL_INCREMENT: 'NUXT_ORACLE_POOL_INCREMENT',
  REDIS_URL: 'NUXT_REDIS_URL',
  REDIS_HOST: 'NUXT_REDIS_HOST',
  REDIS_PORT: 'NUXT_REDIS_PORT',
  REDIS_DB: 'NUXT_REDIS_DB',
  REDIS_PASSWORD: 'NUXT_REDIS_PASSWORD',
  SMTP_HOST: 'NUXT_SMTP_HOST',
  SMTP_PORT: 'NUXT_SMTP_PORT',
  SMTP_USER: 'NUXT_SMTP_USER',
  SMTP_PASS: 'NUXT_SMTP_PASS',
  SENTIMENTFLOW_ENABLED: 'NUXT_SENTIMENT_FLOW_ENABLED',
  SENTIMENTFLOW_BASE_URL: 'NUXT_SENTIMENT_FLOW_BASE_URL',
  SENTIMENTFLOW_TIMEOUT_MS: 'NUXT_SENTIMENT_FLOW_TIMEOUT_MS',
  NLS_LANG: 'NUXT_NLS_LANG'
};

export function resolveRuntimeEnvironment(input, mode) {
  const env = { ...input };
  for (const [legacy, canonical] of Object.entries(runtimeAliases)) {
    // Explicit NUXT_* settings win, including an intentionally empty value.
    if (env[canonical] !== undefined) env[legacy] = env[canonical];
    else if (env[legacy] !== undefined) env[canonical] = env[legacy];
  }
  env.NODE_ENV = mode === 'dev' ? 'development' : 'production';
  env.NUXT_NODE_ENV = env.NODE_ENV;
  env.NUXT_PUBLIC_SENTIMENT_FLOW_ENABLED ??=
    env.NUXT_SENTIMENT_FLOW_ENABLED ?? 'false';
  return env;
}
