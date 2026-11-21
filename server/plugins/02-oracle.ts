import { defineNitroPlugin } from '#imports';
import {
  closeOraclePool,
  getOracleConnection
} from '~/server/utils/oracle';
import { attachOracleQueryCache } from '~/server/utils/oracle-query-cache';
import { banExpiryIntervalMs, sweepExpiredBans } from '~/server/services/v2/moderation-ban-expiry';
import { logWarn } from '~/server/utils/logging';

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

  nitroApp.hooks.hook('close', async () => {
    clearInterval(interval);
    await sweep;
    await closeOraclePool();
  });
});
