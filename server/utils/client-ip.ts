import type { H3Event } from 'h3';

import { isIP } from 'node:net';

export function canonicalIp(address: string | undefined): string {
  if (!address || address.includes('%')) return 'unknown';
  switch (isIP(address)) {
    case 4: return address;
    case 6: {
      const host = new URL(`http://[${address}]`).hostname.slice(1, -1);
      const mapped = /^::ffff:([\da-f]+):([\da-f]+)$/.exec(host);
      if (!mapped) return host;
      const high = parseInt(mapped[1]!, 16), low = parseInt(mapped[2]!, 16);
      return [high >>> 8, high & 255, low >>> 8, low & 255].join('.');
    }
    default: return 'unknown';
  }
}

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

    const canonical = canonicalIp(ip);
    if (canonical !== 'unknown') {
      return canonical;
    }
  }

  return canonicalIp(event.node.req.socket.remoteAddress);
}
