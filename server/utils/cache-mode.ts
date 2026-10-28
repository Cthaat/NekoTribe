import { randomUUID } from 'node:crypto';

// Cached results are safe only when all writes pass through Nuxt's invalidator.
// Keep each process's cache identity separate from previous deployments, since
// other backends may have modified shared data while caching was disabled.
export const singleBackendCacheEnabled = process.env.NEKO_CACHE_MODE === 'single-backend';
export const cacheProcessEpoch = randomUUID();
