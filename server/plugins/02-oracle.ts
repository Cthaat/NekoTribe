import { defineNitroPlugin } from '#imports';
import {
  closeOraclePool,
  getOracleConnection
} from '~/server/utils/oracle';
import { attachOracleQueryCache, attachOracleQueryCacheWithSource } from '~/server/utils/oracle-query-cache';
import { banExpiryIntervalMs, sweepExpiredBans } from '~/server/services/v2/moderation-ban-expiry';
import { postDraftSweepIntervalMs, sweepPostDrafts } from '~/server/services/v2/post-drafts';
import { logWarn } from '~/server/utils/logging';
import { getRedisClient } from '~/server/utils/redis';

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('request', event => {
    Object.defineProperty(event.context, 'getOracleConnection', {
      get() {
        return async () =>
          attachOracleQueryCache(
            event,
            await getOracleConnection()
          );
      },
      configurable: true
    });
  });

  let sweep: Promise<void> | undefined;
  const interval = setInterval(() => {
    if (sweep) return;
    sweep = (async () => {
      const connection = await getOracleConnection();
      try { await sweepExpiredBans(connection); }
      finally { await connection.close(); }
    })().catch(() => logWarn('moderation:ban-expiry:unavailable', {}))
      .finally(() => { sweep = undefined; });
  }, banExpiryIntervalMs);
  interval.unref();

  let publication: Promise<void> | undefined;
  const draftInterval = setInterval(() => {
    if (publication) return;
    publication = (async () => {
      const connection = await getOracleConnection();
      try {
        await sweepPostDrafts(attachOracleQueryCacheWithSource({redis: getRedisClient()}, connection));
      } finally { await connection.close(); }
    })().catch(() => logWarn('post-draft:sweep-unavailable', {}))
      .finally(() => { publication = undefined; });
  }, postDraftSweepIntervalMs);
  draftInterval.unref();

  nitroApp.hooks.hook('close', async () => {
    clearInterval(interval);
    clearInterval(draftInterval);
    await Promise.all([sweep, publication]);
    await closeOraclePool();
  });
});
