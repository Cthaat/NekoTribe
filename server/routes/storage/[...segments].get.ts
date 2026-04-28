import {
  type H3Event,
  sendStream,
  setResponseHeader,
  setResponseStatus
} from 'h3';
import {
  DEFAULT_AVATAR_STORAGE_KEY,
  getStorageProvider,
  managedPublicUrlToStorageKey
} from '~/server/storage';
import { StorageHttpError } from '~/server/storage/http';

const DEFAULT_AVATAR_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAQAAAAAYLlVAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAiklEQVR4nO3XwQmAMBAEwTn77y6doC3YgGCWoJcQecBqYSkAAAAAAAAAAAAAAGBc2q7r+7y7e0T7Yx5smN1vyXodD9bK7q7I0cxdMM9wPZz8x0y2H2Y9nLxj5mx1dbrYqX5cJ8eVnqE7x1B8hTn7gk3f4g0AAAAAAAAAAAAAAIB3bQF6rA1Xj2GmQAAAAABJRU5ErkJggg==',
  'base64'
);

function sendDefaultAvatar(event: H3Event) {
  setResponseStatus(event, 200);
  setResponseHeader(event, 'Content-Type', 'image/png');
  setResponseHeader(
    event,
    'Cache-Control',
    'public, max-age=31536000, immutable'
  );
  setResponseHeader(
    event,
    'Content-Length',
    DEFAULT_AVATAR_PNG.length
  );
  return DEFAULT_AVATAR_PNG;
}

export default defineEventHandler(async event => {
  const segments = getRouterParam(event, 'segments');
  if (!segments) {
    throw createError({
      statusCode: 404,
      statusMessage: 'Not Found'
    });
  }

  const key =
    managedPublicUrlToStorageKey(`/storage/${segments}`) ||
    segments;

  try {
    const result = await getStorageProvider().readObject(key, {
      rangeHeader:
        event.node.req.headers.range?.toString() || null
    });

    setResponseStatus(event, result.statusCode);
    for (const [header, value] of Object.entries(
      result.headers
    )) {
      setResponseHeader(event, header, value);
    }

    return sendStream(event, result.stream);
  } catch (error) {
    if (
      error instanceof StorageHttpError &&
      error.statusCode === 404 &&
      key === DEFAULT_AVATAR_STORAGE_KEY
    ) {
      return sendDefaultAvatar(event);
    }

    if (error instanceof StorageHttpError) {
      throw createError({
        statusCode: error.statusCode,
        statusMessage: error.message
      });
    }

    throw error;
  }
});
