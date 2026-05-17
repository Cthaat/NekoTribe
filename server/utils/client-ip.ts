import type { H3Event } from 'h3';

function trustProxyHeaders(): boolean {
  return ['1', 'true', 'yes', 'on'].includes(
    String(process.env.TRUST_PROXY ?? '')
      .trim()
      .toLowerCase()
  );
}

export function getClientIp(event: H3Event): string {
  if (trustProxyHeaders()) {
    const forwardedFor =
      event.node.req.headers['x-forwarded-for'];
    const forwardedIp = Array.isArray(forwardedFor)
      ? forwardedFor[0]
      : forwardedFor;
    const ip = forwardedIp
      ?.toString()
      .split(',')[0]
      ?.trim();

    if (ip) {
      return ip;
    }
  }

  return event.node.req.socket.remoteAddress || 'unknown';
}
