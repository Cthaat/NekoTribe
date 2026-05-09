import { defineNitroPlugin } from '#imports';
import {
  closeOraclePool,
  getOracleConnection
} from '~/server/utils/oracle';

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('request', event => {
    Object.defineProperty(event.context, 'getOracleConnection', {
      get() {
        return getOracleConnection;
      },
      configurable: true
    });
  });

  nitroApp.hooks.hook('close', closeOraclePool);
});
