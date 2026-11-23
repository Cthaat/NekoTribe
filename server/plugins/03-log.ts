import type { OutgoingHttpHeader, OutgoingHttpHeaders } from 'node:http';
import {
  createRequestLogContext,
  logInfo
} from '~/server/utils/logging';
import { observeHttp } from '~/server/utils/observability';

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('request', event => {
    const context = createRequestLogContext(event);
    const startedAt = performance.now();
    const response = event.node.res;
    const writeHead = response.writeHead;
    response.writeHead = function (...args: [number, (OutgoingHttpHeaders | OutgoingHttpHeader[] | string)?, (OutgoingHttpHeaders | OutgoingHttpHeader[])?]) {
      const result = Reflect.apply(writeHead, response, args) as typeof response;
      if (response.statusCode >= 200 || response.statusCode === 101) {
        response.writeHead = writeHead;
        const elapsed = performance.now() - startedAt;
        if (!/^\/metrics\/*$/.test(context.path)) observeHttp(context.method, response.statusCode, elapsed / 1000);
        logInfo('http:response', {
          request_id: context.requestId,
          method: context.method,
          path: context.path,
          statusCode: response.statusCode,
          durationMs: Math.floor(elapsed)
        });
      }
      return result;
    };
    logInfo('http:request', {
      request_id: context.requestId,
      method: context.method,
      path: context.path,
      ip: context.ip,
      userAgent: context.userAgent,
      client: context.client
    });
  });
});
