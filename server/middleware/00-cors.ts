import {
  defineEventHandler,
  getHeader,
  getRequestURL,
  getResponseHeader,
  setResponseHeader,
  setResponseStatus
} from 'h3';
import { corsHeadersForRequest, mergeCorsVary } from '../utils/cors';

// Nitro registers server middleware by filename: preflight must finish before auth.
export default defineEventHandler(event => {
  if (!getRequestURL(event).pathname.startsWith('/api/')) return;
  setResponseHeader(event, 'Vary', mergeCorsVary(getResponseHeader(event, 'Vary')));
  const preflight = event.method === 'OPTIONS';
  const origin = getHeader(event, 'origin');
  const headers = corsHeadersForRequest({
    origin,
    requestHeaders: preflight ? getHeader(event, 'access-control-request-headers') : undefined,
    requestMethod: preflight ? getHeader(event, 'access-control-request-method') : undefined
  });
  if (headers) {
    for (const [name, value] of Object.entries(headers)) setResponseHeader(event, name, value);
  }
  if (preflight) {
    setResponseStatus(event, origin && !headers ? 403 : 204);
    return '';
  }
});
