import {
  defineEventHandler,
  getHeader,
  getRequestURL,
  setResponseHeader,
  setResponseStatus
} from 'h3';
import { corsHeadersForRequest } from '../utils/cors';

export default defineEventHandler(event => {
  const url = getRequestURL(event);
  if (!url.pathname.startsWith('/api/')) return;

  const headers = corsHeadersForRequest({
    origin: getHeader(event, 'origin'),
    requestHeaders: getHeader(
      event,
      'access-control-request-headers'
    )
  });

  if (headers) {
    for (const [name, value] of Object.entries(headers)) {
      setResponseHeader(event, name, value);
    }
    setResponseHeader(event, 'Vary', 'Origin');
  }

  if ((event.node.req.method || 'GET').toUpperCase() === 'OPTIONS') {
    setResponseStatus(event, 204);
    return '';
  }
});
