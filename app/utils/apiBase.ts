interface PublicEndpointConfig {
  apiBase?: unknown;
  wsUrl?: unknown;
  storageBase?: unknown;
}

function readEndpointConfig(): PublicEndpointConfig {
  try {
    return useRuntimeConfig().public;
  } catch {
    return {};
  }
}

export function resolveApiBaseUrl(config = readEndpointConfig()): string {
  return String(config.apiBase ?? '').trim().replace(/\/+$/, '');
}

export function resolveApiRequestBase(
  config: { public: PublicEndpointConfig; apiServerBase?: string } | undefined,
  isServer: boolean
): string {
  const address = isServer ? config?.apiServerBase?.trim() : undefined;
  if (!address) return resolveApiBaseUrl(config?.public);

  const authority = /^https?:\/\/([^/]+)(?:\/|$)/i.exec(address)?.[1];
  const url = URL.canParse(address) ? new URL(address) : undefined;
  if (!authority || authority.includes('@') || /[?#\\\s]/.test(address) ||
      !url || url.port === '0') {
    throw new Error('NUXT_API_SERVER_BASE must be an absolute HTTP(S) base URL without credentials, query or fragment.');
  }
  return url.origin + url.pathname.replace(/\/+$/, '');
}

export function joinStorageBaseUrl(path: string, config = readEndpointConfig()): string {
  const override = String(config.storageBase ?? '').trim();
  let base = resolveApiBaseUrl(config);
  if (override) {
    try {
      const url = new URL(override);
      if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password &&
          !url.search && !url.hash) {
        base = url.origin + url.pathname.replace(/\/+$/, '');
      }
    } catch {
      // Keep the API base for an invalid storage override.
    }
  }
  if (!base) return path;
  const trimmedPath = path.startsWith('/') ? path : `/${path}`;
  return `${base}${trimmedPath}`;
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
  config?: PublicEndpointConfig;
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
  if (!configured) return null;

  const url = parseAbsoluteUrl(configured);
  if (!url || !['http:', 'https:', 'ws:', 'wss:'].includes(url.protocol) ||
      url.username || url.password || url.hash) return null;

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
  if (!url || !['http:', 'https:'].includes(url.protocol) ||
      url.username || url.password || url.search || url.hash) return null;

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

  const config = options.config ?? readEndpointConfig();
  const explicit = normalizeRealtimeFromExplicit(String(config.wsUrl ?? '').trim(), ctx);
  if (explicit) return explicit;

  const derived = normalizeRealtimeFromApiBase(resolveApiBaseUrl(config), ctx);
  if (derived) return derived;

  return sameOriginRealtimeUrl(ctx) ?? '/_ws';
}
