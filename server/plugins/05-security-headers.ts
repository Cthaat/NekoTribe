import { setResponseHeader } from 'h3';

export default defineNitroPlugin(nitroApp => {
  nitroApp.hooks.hook('beforeResponse', event => {
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
      'camera=(), microphone=(), geolocation=()'
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
