import { defineEventHandler, setResponseHeader } from 'h3';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { defineV2Handler, type V2RouteHandler } from '~/server/utils/v2';

export function privateAiHandler<T>(handler: V2RouteHandler<T>) {
  const route = defineV2Handler(safeAuthEntry(handler));
  return defineEventHandler(event => {
    setResponseHeader(event, 'Cache-Control', 'private, no-store');
    return route(event);
  });
}
