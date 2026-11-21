import { defineNitroPlugin, useRuntimeConfig } from '#imports';
import { sessionLifetimes } from '../../scripts/runtime-env.mjs';

export default defineNitroPlugin(() => {
  sessionLifetimes(process.env, useRuntimeConfig());
});
