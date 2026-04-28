interface SerializedNitroError {
  name?: string;
  message: string;
  statusCode?: number;
  statusMessage?: string;
  data?: unknown;
  stack?: string;
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

function serializeNitroError(
  error: unknown
): SerializedNitroError {
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
    stack?: string;
  };

  return {
    name: candidate.name,
    message: candidate.message ?? String(error),
    statusCode:
      candidate.statusCode ?? candidate.cause?.statusCode,
    statusMessage:
      candidate.statusMessage ??
      candidate.cause?.statusMessage,
    data: toSerializable(
      candidate.data ?? candidate.cause?.data
    ),
    stack: candidate.stack
  };
}

export default defineNitroPlugin(nitroApp => {
  // 请求到来时
  nitroApp.hooks.hook('request', event => {
    event.context._start = Date.now();
    console.log(
      `global-hooks:[${new Date().toISOString()}] 请求: ${event.path}`
    );
  });

  // 响应发送前
  nitroApp.hooks.hook(
    'beforeResponse',
    (event, response) => {
      const duration =
        Date.now() - (event.context._start || Date.now());
      console.log(
        `global-hooks:[${new Date().toISOString()}] 响应: ${event.path} 用时: ${duration}ms`
      );
    }
  );

  // 捕获全局错误
  nitroApp.hooks.hook('error', (error, event) => {
    console.error(
      `[global-hooks:${new Date().toISOString()}] 全局错误`,
      {
        path: event?.path ?? 'unknown',
        method: event?.method,
        error: serializeNitroError(error)
      }
    );
  });
});
