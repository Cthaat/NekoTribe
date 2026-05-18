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
const UPSTREAM_REDIRECT_STATUSES = new Set([
  301,
  302,
  303,
  307,
  308
]);
const MAX_UPSTREAM_REDIRECTS = 5;
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
  'location',
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

function resolveRedirectTarget(
  baseUrl: string,
  currentUrl: string,
  location: string
): string {
  const redirectUrl = new URL(location, currentUrl);
  const baseWithSlash = baseUrl.endsWith('/')
    ? baseUrl
    : `${baseUrl}/`;
  const base = new URL(baseWithSlash);
  const basePath = base.pathname.endsWith('/')
    ? base.pathname
    : `${base.pathname}/`;

  if (
    redirectUrl.origin !== base.origin ||
    !redirectUrl.pathname.startsWith(basePath)
  ) {
    throw new Error(
      'upstream redirect escaped configured base URL'
    );
  }

  return redirectUrl.toString();
}

function redirectMethod(
  status: number,
  method: string
): string {
  if (status === 303 && method !== 'HEAD') {
    return 'GET';
  }

  if (
    (status === 301 || status === 302) &&
    method === 'POST'
  ) {
    return 'GET';
  }

  return method;
}

async function closeRedirectResponse(
  response: Response
): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // Ignore cleanup errors; the next upstream request is the useful signal.
  }
}

async function fetchSentimentFlowUpstream(options: {
  targetUrl: string;
  baseUrl: string;
  method: string;
  headers: Headers;
  body: string | undefined;
  signal: AbortSignal;
}): Promise<Response> {
  let targetUrl = options.targetUrl;
  let method = options.method;
  let body = options.body;

  for (
    let redirectCount = 0;
    redirectCount <= MAX_UPSTREAM_REDIRECTS;
    redirectCount += 1
  ) {
    const response = await fetch(targetUrl, {
      method,
      headers: options.headers,
      body: BODYLESS_METHODS.has(method) ? undefined : body,
      redirect: 'manual',
      signal: options.signal
    });

    if (!UPSTREAM_REDIRECT_STATUSES.has(response.status)) {
      return response;
    }

    const location = response.headers.get('location');
    if (!location) {
      return response;
    }

    if (redirectCount === MAX_UPSTREAM_REDIRECTS) {
      await closeRedirectResponse(response);
      throw new Error('too many SentimentFlow redirects');
    }

    targetUrl = resolveRedirectTarget(
      options.baseUrl,
      targetUrl,
      location
    );
    const nextMethod = redirectMethod(response.status, method);
    if (nextMethod !== method) {
      method = nextMethod;
      body = undefined;
    }
    await closeRedirectResponse(response);
  }

  throw new Error('too many SentimentFlow redirects');
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
    const upstreamResponse = await fetchSentimentFlowUpstream({
      targetUrl,
      baseUrl: config.baseUrl,
      method,
      headers: forwardRequestHeaders(getRequestHeaders(event)),
      body,
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
