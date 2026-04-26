import {
  sendStream,
  setResponseHeader,
  setResponseStatus
} from 'h3';
import {
  getStorageProvider,
  managedPublicUrlToStorageKey
} from '~/server/storage';
import { StorageHttpError } from '~/server/storage/http';

export default defineEventHandler(async event => {
  const segments = getRouterParam(event, 'segments');
  if (!segments) {
    throw createError({
      statusCode: 404,
      statusMessage: 'Not Found'
    });
  }

  try {
    const key =
      managedPublicUrlToStorageKey(`/uploads/${segments}`) ||
      segments;
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
    if (error instanceof StorageHttpError) {
      throw createError({
        statusCode: error.statusCode,
        statusMessage: error.message
      });
    }

    throw error;
  }
});
