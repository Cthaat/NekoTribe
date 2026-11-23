import type { H3Event } from 'h3';
import {
  getRequestLogContext,
  logError,
  logWarn,
  serializeLogError
} from '~/server/utils/logging';

function shouldLogError(
  path: string,
  statusCode: number
): boolean {
  if (statusCode >= 500) {
    return true;
  }

  return path.startsWith('/api/');
}

function errorEvent(input: unknown): H3Event | undefined {
  const candidate = input as {
    event?: H3Event;
    node?: H3Event['node'];
    context?: H3Event['context'];
  };

  if (candidate?.event) {
    return candidate.event;
  }

  if (candidate?.node && candidate.context) {
    return input as H3Event;
  }

  return undefined;
}

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('error', (error, errorContext) => {
    const event = errorEvent(errorContext);
    const context = getRequestLogContext(event);
    const serialized = serializeLogError(error);
    const statusCode = serialized.statusCode ?? 500;
    const path = context?.path ?? event?.path.split('?', 1)[0] ?? 'unknown';
    const payload = {
      request_id: context?.requestId ?? 'unknown',
      method:
        context?.method ??
        event?.node.req.method ??
        'UNKNOWN',
      path,
      statusCode,
      errorName: serialized.name
    };

    if (!shouldLogError(path, statusCode)) {
      logWarn('http:ignored-error', payload);
      return;
    }

    logError('http:error', payload);
  });
});
