import { defineNitroPlugin } from '#imports';
import {
  closeOraclePool,
  getOracleConnection
} from '~/server/utils/oracle';
import { attachOracleQueryCache } from '~/server/utils/oracle-query-cache';

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

  nitroApp.hooks.hook('close', closeOraclePool);
});
