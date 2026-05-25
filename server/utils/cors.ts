export const DEFAULT_CORS_ALLOWED_HEADERS =
  'authorization,content-type,accept,origin,x-requested-with,' +
  'x-client-platform,x-client-route,x-client-component,' +
  'x-client-source,x-client-referer,x-device-fingerprint';

export const DEFAULT_CORS_ALLOWED_METHODS =
  'GET,POST,PUT,PATCH,DELETE,OPTIONS';

export interface CorsPolicyOptions {
  allowedOrigins?: readonly string[];
  allowLocalhostOrigins?: boolean;
}

interface CorsHeadersOptions extends CorsPolicyOptions {
  origin?: string | null;
  requestHeaders?: string | null;
}

export function parseCorsAllowedOrigins(
  value: string | null | undefined
): string[] {
  if (!value) return [];

  return value
    .split(',')
    .map(item => normalizeOrigin(item))
    .filter((item): item is string => Boolean(item));
}

export function configuredCorsAllowedOrigins(
  env: NodeJS.ProcessEnv = process.env
): string[] {
  return [
    ...parseCorsAllowedOrigins(env.CORS_ALLOWED_ORIGINS),
    ...parseCorsAllowedOrigins(env.NUXT_CORS_ALLOWED_ORIGINS)
  ];
}

export function resolveCorsOrigin(
  origin?: string | null,
  options: CorsPolicyOptions = {}
): string | null {
  const normalized = normalizeOrigin(origin);
  if (!normalized) return null;

  const allowedOrigins =
    options.allowedOrigins ?? configuredCorsAllowedOrigins();
  if (allowedOrigins.includes(normalized)) {
    return normalized;
  }

  if (options.allowLocalhostOrigins !== false) {
    return isLocalhostOrigin(normalized) ? normalized : null;
  }

  return null;
}

export function corsHeadersForRequest(
  options: CorsHeadersOptions
): Record<string, string> | null {
  const allowedOrigin = resolveCorsOrigin(options.origin, options);
  if (!allowedOrigin) return null;

  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Allow-Methods': DEFAULT_CORS_ALLOWED_METHODS,
    'Access-Control-Allow-Headers':
      normalizeHeaderList(options.requestHeaders) ||
      DEFAULT_CORS_ALLOWED_HEADERS,
    'Access-Control-Expose-Headers': 'content-length,content-type',
    'Access-Control-Max-Age': '86400'
  };
}

function normalizeOrigin(value?: string | null): string | null {
  const raw = String(value ?? '').trim();
  if (!raw) return null;

  try {
    return new URL(raw).origin;
  } catch {
    return null;
  }
}

function isLocalhostOrigin(origin: string): boolean {
  try {
    const url = new URL(origin);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      return false;
    }

    const hostname = url.hostname
      .replace(/^\[/, '')
      .replace(/\]$/, '')
      .toLowerCase();
    return (
      hostname === 'localhost' ||
      hostname === '::1' ||
      /^127(?:\.\d{1,3}){3}$/.test(hostname)
    );
  } catch {
    return false;
  }
}

function normalizeHeaderList(value?: string | null): string {
  return String(value ?? '')
    .split(',')
    .map(item => item.trim())
    .filter(Boolean)
    .join(',');
}
