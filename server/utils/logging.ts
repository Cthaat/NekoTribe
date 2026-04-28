import { AsyncLocalStorage } from 'node:async_hooks';
import { randomUUID } from 'node:crypto';
import type { H3Event } from 'h3';
import {
  getHeader,
  getRequestURL,
  setResponseHeader
} from 'h3';

export interface RequestLogContext {
  requestId: string;
  startAt: number;
  method: string;
  rawUrl: string;
  path: string;
  query: Record<string, string>;
  ip: string;
  userAgent: string;
  client: {
    platform: string;
    route: string;
    component: string;
    source: string;
    referer: string;
  };
}

export interface SerializedLogError {
  name?: string;
  message: string;
  statusCode?: number;
  statusMessage?: string;
  data?: unknown;
  stack?: string;
}

interface RequestLogCarrier {
  requestLog?: RequestLogContext;
}

const requestLogStorage =
  new AsyncLocalStorage<RequestLogContext>();

function isH3Event(event: unknown): event is H3Event {
  return (
    !!event &&
    typeof event === 'object' &&
    'context' in event &&
    'node' in event
  );
}

function headerValue(value: unknown): string {
  if (Array.isArray(value)) {
    return value.join(',');
  }
  return typeof value === 'string' && value.length > 0
    ? value
    : '-';
}

function toSerializable(value: unknown): unknown {
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return value;
  }

  if (Array.isArray(value)) {
    return value.map(toSerializable);
  }

  if (typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(
        ([key, item]) => [key, toSerializable(item)]
      )
    );
  }

  return String(value);
}

function requestIp(event: H3Event): string {
  return (
    getHeader(event, 'x-forwarded-for')
      ?.toString()
      .split(',')[0]
      ?.trim() ||
    event.node.req.socket.remoteAddress ||
    'unknown'
  );
}

function queryRecord(url: URL): Record<string, string> {
  return Object.fromEntries(url.searchParams.entries());
}

export function createRequestLogContext(
  event: H3Event
): RequestLogContext {
  const requestId =
    getHeader(event, 'x-request-id')?.toString().trim() ||
    randomUUID();
  const url = getRequestURL(event);
  const context: RequestLogContext = {
    requestId,
    startAt: Date.now(),
    method: event.node.req.method || 'UNKNOWN',
    rawUrl: event.node.req.url || url.pathname,
    path: url.pathname,
    query: queryRecord(url),
    ip: requestIp(event),
    userAgent:
      getHeader(event, 'user-agent')?.toString() ||
      'unknown',
    client: {
      platform: headerValue(
        event.node.req.headers['x-client-platform']
      ),
      route: headerValue(
        event.node.req.headers['x-client-route']
      ),
      component: headerValue(
        event.node.req.headers['x-client-component']
      ),
      source: headerValue(
        event.node.req.headers['x-client-source']
      ),
      referer: headerValue(
        event.node.req.headers['x-client-referer'] ||
          event.node.req.headers.referer
      )
    }
  };

  (event.context as RequestLogCarrier).requestLog = context;
  requestLogStorage.enterWith(context);
  setResponseHeader(event, 'x-request-id', requestId);

  return context;
}

export function getRequestLogContext(
  event: unknown
): RequestLogContext | null {
  if (!isH3Event(event)) {
    return requestLogStorage.getStore() ?? null;
  }

  return (
    (event.context as RequestLogCarrier).requestLog ??
    requestLogStorage.getStore() ??
    null
  );
}

export function serializeLogError(
  error: unknown
): SerializedLogError {
  const candidate = error as {
    name?: string;
    message?: string;
    statusCode?: number;
    statusMessage?: string;
    data?: unknown;
    cause?: {
      statusCode?: number;
      statusMessage?: string;
      data?: unknown;
    };
    response?: {
      status?: number;
      statusText?: string;
      _data?: unknown;
    };
    stack?: string;
  };

  return {
    name: candidate.name,
    message: candidate.message ?? String(error),
    statusCode:
      candidate.statusCode ??
      candidate.cause?.statusCode ??
      candidate.response?.status,
    statusMessage:
      candidate.statusMessage ??
      candidate.cause?.statusMessage ??
      candidate.response?.statusText,
    data: toSerializable(
      candidate.data ??
        candidate.cause?.data ??
        candidate.response?._data
    ),
    stack: candidate.stack
  };
}

export function logInfo(
  scope: string,
  payload: Record<string, unknown>
): void {
  console.info(`[${scope}]`, payload);
}

export function logWarn(
  scope: string,
  payload: Record<string, unknown>
): void {
  console.warn(`[${scope}]`, payload);
}

export function logError(
  scope: string,
  payload: Record<string, unknown>
): void {
  console.error(`[${scope}]`, payload);
}
