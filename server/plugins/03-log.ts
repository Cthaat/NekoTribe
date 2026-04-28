import {
  createRequestLogContext,
  logInfo
} from '~/server/utils/logging';

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('request', event => {
    const context = createRequestLogContext(event);
    logInfo('http:request', {
      requestId: context.requestId,
      method: context.method,
      path: context.path,
      rawUrl: context.rawUrl,
      query: context.query,
      ip: context.ip,
      userAgent: context.userAgent,
      client: context.client
    });
  });
});
