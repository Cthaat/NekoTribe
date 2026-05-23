function readApiBase(): string {
  try {
    return String(useRuntimeConfig().public.apiBase ?? '').trim();
  } catch {
    return '';
  }
}

function readWsUrl(): string {
  try {
    return String(useRuntimeConfig().public.wsUrl ?? '').trim();
  } catch {
    return '';
  }
}

export function resolveApiBaseUrl(): string {
  return readApiBase();
}

export function joinApiBaseUrl(path: string): string {
  const base = readApiBase();
  if (!base) return path;
  const trimmedBase = base.replace(/\/+$/, '');
  const trimmedPath = path.startsWith('/') ? path : `/${path}`;
  return `${trimmedBase}${trimmedPath}`;
}

function browserOrigin(): string {
  if (typeof window === 'undefined') return 'http://localhost';
  return window.location.origin;
}

function toWsProtocol(protocol: string): string {
  if (protocol === 'http:') return 'ws:';
  if (protocol === 'https:') return 'wss:';
  return protocol;
}

function parseAbsoluteUrl(value: string): URL | null {
  try {
    return new URL(value, browserOrigin());
  } catch {
    return null;
  }
}

function isLocalOnlyHostname(hostname: string): boolean {
  const normalized = hostname
    .trim()
    .replace(/^\[|\]$/g, '')
    .toLowerCase();
  return (
    !normalized ||
    normalized === 'localhost' ||
    normalized === '0.0.0.0' ||
    normalized === '::' ||
    normalized === '::1' ||
    normalized.startsWith('127.')
  );
}

export interface ResolveRealtimeUrlOptions {
  // Browser hostname when called from client; used to detect a local-only
  // configured URL that would not be reachable from a remote browser.
  browserHostname?: string;
  // Browser protocol ('http:' or 'https:') used to upgrade ws → wss when
  // the page is HTTPS but the configured URL is ws.
  browserProtocol?: string;
}

function normalizeRealtimeFromExplicit(
  configured: string,
  options: ResolveRealtimeUrlOptions
): string | null {
  if (!configured || configured.includes('localhost:3000')) {
    return null;
  }

  const url = parseAbsoluteUrl(configured);
  if (!url) return null;

  if (url.protocol === 'http:') url.protocol = 'ws:';
  else if (url.protocol === 'https:') url.protocol = 'wss:';

  const browserHostname = options.browserHostname ?? '';
  const browserProtocol = options.browserProtocol ?? '';
  const configuredIsLocal = isLocalOnlyHostname(url.hostname);
  const browserIsLocal = isLocalOnlyHostname(browserHostname);

  if (configuredIsLocal && browserHostname && !browserIsLocal) {
    return null;
  }

  if (['0.0.0.0', '::', '[::]'].includes(url.hostname)) {
    if (browserHostname && !browserIsLocal) {
      url.hostname = browserHostname;
    } else {
      url.hostname = 'localhost';
    }
  }

  if (browserProtocol === 'https:' && url.protocol === 'ws:') {
    url.protocol = 'wss:';
  }

  return url.toString();
}

function normalizeRealtimeFromApiBase(
  apiBase: string,
  options: ResolveRealtimeUrlOptions
): string | null {
  if (!apiBase) return null;

  const url = parseAbsoluteUrl(apiBase);
  if (!url) return null;

  url.protocol = toWsProtocol(url.protocol);

  const browserHostname = options.browserHostname ?? '';
  const browserProtocol = options.browserProtocol ?? '';
  const configuredIsLocal = isLocalOnlyHostname(url.hostname);
  const browserIsLocal = isLocalOnlyHostname(browserHostname);

  if (configuredIsLocal && browserHostname && !browserIsLocal) {
    return null;
  }

  if (['0.0.0.0', '::', '[::]'].includes(url.hostname)) {
    if (browserHostname && !browserIsLocal) {
      url.hostname = browserHostname;
    } else {
      url.hostname = 'localhost';
    }
  }

  if (browserProtocol === 'https:' && url.protocol === 'ws:') {
    url.protocol = 'wss:';
  }

  const trimmedPath = url.pathname.replace(/\/+$/, '');
  return `${url.protocol}//${url.host}${trimmedPath}/_ws`;
}

function sameOriginRealtimeUrl(
  options: ResolveRealtimeUrlOptions
): string | null {
  if (typeof window === 'undefined') return null;
  const protocol =
    (options.browserProtocol ?? window.location.protocol) ===
    'https:'
      ? 'wss:'
      : 'ws:';
  return `${protocol}//${window.location.host}/_ws`;
}

export function resolveRealtimeUrl(
  options: ResolveRealtimeUrlOptions = {}
): string {
  const browserHostname =
    options.browserHostname ??
    (typeof window === 'undefined' ? '' : window.location.hostname);
  const browserProtocol =
    options.browserProtocol ??
    (typeof window === 'undefined' ? '' : window.location.protocol);
  const ctx: ResolveRealtimeUrlOptions = {
    browserHostname,
    browserProtocol
  };

  const explicit = normalizeRealtimeFromExplicit(readWsUrl(), ctx);
  if (explicit) return explicit;

  const derived = normalizeRealtimeFromApiBase(readApiBase(), ctx);
  if (derived) return derived;

  return sameOriginRealtimeUrl(ctx) ?? '/_ws';
}
