import { getRequestURL, getResponseHeader, getResponseStatus, setResponseHeader } from 'h3';
import { isChatPath } from '#shared/utils/chat-document';

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('beforeResponse', event => {
    const chatDocument = isChatPath(getRequestURL(event).pathname) &&
      getResponseStatus(event) === 200 && getResponseHeader(event, 'x-powered-by') === 'Nuxt' &&
      /^text\/html(?:;|$)/i.test(String(getResponseHeader(event, 'content-type')));
    setResponseHeader(
      event,
      'X-Content-Type-Options',
      'nosniff'
    );
    setResponseHeader(event, 'X-Frame-Options', 'DENY');
    setResponseHeader(
      event,
      'Referrer-Policy',
      'same-origin'
    );
    setResponseHeader(
      event,
      'Permissions-Policy',
      chatDocument ? 'camera=(self), microphone=(self), geolocation=()' : 'camera=(), microphone=(), geolocation=()'
    );

    if (process.env.COOKIE_SECURE === 'true') {
      setResponseHeader(
        event,
        'Strict-Transport-Security',
        'max-age=31536000; includeSubDomains'
      );
    }
  });
});
