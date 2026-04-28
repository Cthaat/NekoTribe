import type { H3Event } from 'h3';
import {
  getRequestLogContext,
  logError,
  logInfo,
  logWarn,
  serializeLogError
} from '~/server/utils/logging';

function responseStatus(
  event: H3Event,
  response: unknown
): number {
  const candidate = response as {
    statusCode?: number;
    status?: number;
  };
  return (
    candidate.statusCode ??
    candidate.status ??
    event.node.res.statusCode
  );
}

function shouldLogError(
  path: string,
  statusCode: number
): boolean {
  if (statusCode >= 500) {
    return true;
  }

  return path.startsWith('/api/');
}

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook(
    'beforeResponse',
    (event, response) => {
      const context = getRequestLogContext(event);
      const statusCode = responseStatus(event, response);
      const durationMs =
        Date.now() - (context?.startAt ?? Date.now());

      logInfo('http:response', {
        requestId: context?.requestId ?? 'unknown',
        method:
          context?.method ||
          event.node.req.method ||
          'UNKNOWN',
        path: context?.path ?? event.path,
        rawUrl: context?.rawUrl ?? event.node.req.url,
        statusCode,
        durationMs
      });
    }
  );

  nitroApp.hooks.hook('error', (error, event) => {
    const context = getRequestLogContext(event);
    const serialized = serializeLogError(error);
    const statusCode = serialized.statusCode ?? 500;
    const path = context?.path ?? event?.path ?? 'unknown';
    const payload = {
      requestId: context?.requestId ?? 'unknown',
      method: context?.method ?? event?.method ?? 'UNKNOWN',
      path,
      rawUrl:
        context?.rawUrl ??
        event?.node?.req?.url ??
        path,
      statusCode,
      error: serialized
    };

    if (!shouldLogError(path, statusCode)) {
      logWarn('http:ignored-error', payload);
      return;
    }

    logError('http:error', payload);
  });
});
