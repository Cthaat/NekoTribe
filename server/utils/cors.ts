export const DEFAULT_CORS_ALLOWED_HEADERS =
  'authorization,content-type,accept,origin,x-requested-with,' +
  'x-client-platform,x-client-route,x-client-component,' +
  'x-client-source,x-client-referer,x-device-fingerprint,x-device-info';

export const DEFAULT_CORS_ALLOWED_METHODS =
  'GET,POST,PUT,PATCH,DELETE,OPTIONS';

export interface CorsPolicyOptions {
  allowedOrigins?: readonly string[];
  allowLocalhostOrigins?: boolean;
}

interface CorsHeadersOptions extends CorsPolicyOptions {
  origin?: string | null;
  requestHeaders?: string | null;
  requestMethod?: string | null;
}

// An Origin is a serialized HTTP(S) origin, never a URL with credentials/path.
function normalizeOrigin(value?: string | null): string | null {
  if (!value || value !== value.trim()) return null;
  try {
    const url = new URL(value);
    return (url.protocol === 'http:' || url.protocol === 'https:') &&
      value === url.origin ? url.origin : null;
  } catch {
    return null;
  }
}

export function parseCorsAllowedOrigins(value?: string | null): string[] {
  return [...new Set((value ?? '').split(',')
    .map(item => normalizeOrigin(item.trim()))
    .filter((item): item is string => item !== null))];
}

export function configuredCorsAllowedOrigins(
  env: NodeJS.ProcessEnv = process.env
): string[] {
  return [
    ...parseCorsAllowedOrigins(env.CORS_ALLOWED_ORIGINS),
    ...parseCorsAllowedOrigins(env.NUXT_CORS_ALLOWED_ORIGINS)
  ];
}

export function configuredCorsLocalhost(
  env: NodeJS.ProcessEnv = process.env
): boolean {
  const configured = env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS ??
    env.CORS_ALLOW_LOCALHOST_ORIGINS;
  return configured === undefined
    ? env.NODE_ENV === 'development'
    : configured === 'true';
}

export function resolveCorsOrigin(
  origin?: string | null,
  options: CorsPolicyOptions = {}
): string | null {
  const normalized = normalizeOrigin(origin);
  if (!normalized) return null;
  if ((options.allowedOrigins ?? configuredCorsAllowedOrigins()).includes(normalized)) {
    return normalized;
  }
  if (options.allowLocalhostOrigins ?? configuredCorsLocalhost()) {
    const hostname = new URL(normalized).hostname;
    if (hostname === 'localhost' || hostname === '[::1]' ||
        /^127(?:\.\d{1,3}){3}$/.test(hostname)) return normalized;
  }
  return null;
}

export function corsHeadersForRequest(
  options: CorsHeadersOptions
): Record<string, string> | null {
  const allowedOrigin = resolveCorsOrigin(options.origin, options);
  if (!allowedOrigin) return null;
  if (options.requestMethod != null &&
      !DEFAULT_CORS_ALLOWED_METHODS.split(',').includes(options.requestMethod)) return null;
  const requested = options.requestHeaders == null ? [] :
    options.requestHeaders.split(',').map(header => header.trim().toLowerCase());
  const allowed = DEFAULT_CORS_ALLOWED_HEADERS.split(',');
  if (requested.some(header => !allowed.includes(header))) return null;
  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Allow-Methods': DEFAULT_CORS_ALLOWED_METHODS,
    'Access-Control-Allow-Headers': requested.length
      ? [...new Set(requested)].join(',') : DEFAULT_CORS_ALLOWED_HEADERS,
    'Access-Control-Expose-Headers': 'content-length,content-type',
    'Access-Control-Max-Age': '86400'
  };
}

export function mergeCorsVary(existing: string | number | string[] | undefined): string {
  const values = String(existing ?? '').split(',').map(value => value.trim()).filter(Boolean);
  if (values.includes('*')) return '*';
  for (const value of ['Origin', 'Access-Control-Request-Method', 'Access-Control-Request-Headers']) {
    if (!values.some(existing => existing.toLowerCase() === value.toLowerCase())) values.push(value);
  }
  return values.join(', ');
}
