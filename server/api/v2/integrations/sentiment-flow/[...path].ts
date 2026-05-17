import {
  createError,
  defineEventHandler,
  getMethod,
  getQuery,
  getRequestHeaders,
  getRouterParam,
  readRawBody
} from 'h3';
import {
  buildSentimentFlowTargetUrl,
  resolveSentimentFlowConfig
} from '~/server/utils/sentiment-flow';

const BODYLESS_METHODS = new Set(['GET', 'HEAD']);
const BLOCKED_REQUEST_HEADERS = new Set([
  'host',
  'connection',
  'content-length',
  'transfer-encoding',
  'upgrade',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'authorization',
  'te',
  'trailer',
  'cookie'
]);
const BLOCKED_RESPONSE_HEADERS = new Set([
  'connection',
  'content-length',
  'content-encoding',
  'transfer-encoding',
  'upgrade',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer'
]);

function v2ProxyError(
  statusCode: number,
  message: string,
  detail?: string
): never {
  throw createError({
    statusCode,
    statusMessage: message,
    data: {
      code: statusCode * 100 + 1,
      message,
      data: detail ? { detail } : null,
      meta: null
    }
  });
}

function forwardRequestHeaders(
  headers: Record<string, string | undefined>
): Headers {
  const result = new Headers();

  for (const [key, value] of Object.entries(headers)) {
    if (!value) {
      continue;
    }

    if (BLOCKED_REQUEST_HEADERS.has(key.toLowerCase())) {
      continue;
    }

    result.set(key, value);
  }

  return result;
}

function forwardResponseHeaders(headers: Headers): Headers {
  const result = new Headers();

  headers.forEach((value, key) => {
    if (!BLOCKED_RESPONSE_HEADERS.has(key.toLowerCase())) {
      result.set(key, value);
    }
  });

  return result;
}

function isAbortError(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.name === 'AbortError' ||
      error.message.toLowerCase().includes('aborted'))
  );
}

export default defineEventHandler(async event => {
  const config = resolveSentimentFlowConfig();

  if (!config.enabled) {
    v2ProxyError(
      503,
      'SentimentFlow integration is disabled'
    );
  }

  if (!config.baseUrl) {
    v2ProxyError(
      500,
      'SentimentFlow base URL is not configured'
    );
  }

  const method = getMethod(event).toUpperCase();
  const path = getRouterParam(event, 'path') ?? '';
  let targetUrl: string;
  try {
    targetUrl = buildSentimentFlowTargetUrl(
      config.baseUrl,
      path,
      getQuery(event)
    );
  } catch (error) {
    v2ProxyError(
      400,
      'Invalid SentimentFlow proxy path',
      error instanceof Error ? error.message : undefined
    );
  }
  const body = BODYLESS_METHODS.has(method)
    ? undefined
    : await readRawBody(event);
  const abortController = new AbortController();
  const timeoutId = setTimeout(
    () => abortController.abort(),
    config.timeoutMs
  );

  try {
    const upstreamResponse = await fetch(targetUrl, {
      method,
      headers: forwardRequestHeaders(getRequestHeaders(event)),
      body,
      redirect: 'manual',
      signal: abortController.signal
    });

    return new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      statusText: upstreamResponse.statusText,
      headers: forwardResponseHeaders(upstreamResponse.headers)
    });
  } catch (error) {
    if (isAbortError(error)) {
      v2ProxyError(
        504,
        'SentimentFlow request timed out'
      );
    }

    v2ProxyError(
      502,
      'SentimentFlow upstream request failed',
      error instanceof Error ? error.message : String(error)
    );
  } finally {
    clearTimeout(timeoutId);
  }
});
