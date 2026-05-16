import { useRuntimeConfig } from '#imports';

export const SENTIMENT_FLOW_PROXY_BASE_PATH =
  '/api/v2/integrations/sentiment-flow';

export interface SentimentFlowRuntimeConfig {
  enabled: boolean;
  baseUrl: string;
  timeoutMs: number;
}

export interface SentimentFlowIntegrationInfo {
  enabled: boolean;
  baseUrlConfigured: boolean;
  proxyBasePath: string;
  timeoutMs: number;
}

function normalizeBaseUrl(value: string | undefined): string {
  return (value ?? '').trim().replace(/\/+$/, '');
}

function defaultHostBaseUrl(): string {
  const port =
    process.env.SENTIMENTFLOW_HOST_PORT ||
    process.env.SENTIMENTFLOW_CONTAINER_PORT ||
    '8846';
  return `http://localhost:${port}/api`;
}

function runtimeValue(
  keys: string[],
  fallback: unknown
): string | undefined {
  for (const key of keys) {
    const value = process.env[key];
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
  }

  if (typeof fallback === 'string' && fallback.length > 0) {
    return fallback;
  }

  if (typeof fallback === 'boolean') {
    return fallback ? 'true' : 'false';
  }

  if (typeof fallback === 'number') {
    return String(fallback);
  }

  return undefined;
}

function parseBoolean(value: string | undefined): boolean {
  return ['1', 'true', 'yes', 'on'].includes(
    (value ?? '').trim().toLowerCase()
  );
}

function parseTimeoutMs(
  value: string | undefined,
  fallback: number
): number {
  const parsed = Number.parseInt(value ?? '', 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }

  return Math.min(Math.max(parsed, 1000), 120000);
}

function appendQuery(
  url: URL,
  query: Record<string, unknown>
): void {
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null) {
      continue;
    }

    if (Array.isArray(value)) {
      for (const item of value) {
        if (item !== undefined && item !== null) {
          url.searchParams.append(key, String(item));
        }
      }
      continue;
    }

    url.searchParams.append(key, String(value));
  }
}

export function resolveSentimentFlowConfig(): SentimentFlowRuntimeConfig {
  const runtimeConfig = useRuntimeConfig();
  const configRecord = runtimeConfig as unknown as Record<
    string,
    unknown
  >;
  const publicConfig = (configRecord.public ?? {}) as Record<
    string,
    unknown
  >;

  const enabled = parseBoolean(
    runtimeValue(
      ['NUXT_SENTIMENT_FLOW_ENABLED', 'SENTIMENTFLOW_ENABLED'],
      configRecord.sentimentFlowEnabled ??
        publicConfig.sentimentFlowEnabled
    )
  );
  const baseUrl = normalizeBaseUrl(
    runtimeValue(
      [
        'NUXT_SENTIMENT_FLOW_BASE_URL',
        'SENTIMENTFLOW_BASE_URL'
      ],
      configRecord.sentimentFlowBaseUrl || defaultHostBaseUrl()
    )
  );
  const timeoutMs = parseTimeoutMs(
    runtimeValue(
      [
        'NUXT_SENTIMENT_FLOW_TIMEOUT_MS',
        'SENTIMENTFLOW_TIMEOUT_MS'
      ],
      configRecord.sentimentFlowTimeoutMs
    ),
    10000
  );

  return {
    enabled,
    baseUrl,
    timeoutMs
  };
}

export function sentimentFlowIntegrationInfo(): SentimentFlowIntegrationInfo {
  const config = resolveSentimentFlowConfig();

  return {
    enabled: config.enabled,
    baseUrlConfigured: config.baseUrl.length > 0,
    proxyBasePath: SENTIMENT_FLOW_PROXY_BASE_PATH,
    timeoutMs: config.timeoutMs
  };
}

export function buildSentimentFlowTargetUrl(
  baseUrl: string,
  path: string,
  query: Record<string, unknown>
): string {
  const baseWithSlash = baseUrl.endsWith('/')
    ? baseUrl
    : `${baseUrl}/`;
  const normalizedPath = path.replace(/^\/+/, '');
  const url = new URL(normalizedPath, baseWithSlash);
  appendQuery(url, query);
  return url.toString();
}
