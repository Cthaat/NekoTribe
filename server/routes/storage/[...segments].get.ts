import {
  type H3Event,
  send,
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
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAA/UlEQVR42u2YOw4CMQxENyOuyg2oKai5AbejouQI9FCQOJOf8lyuVva8OJE/6fl6HyubjsUNAAAAAAAAAJa2UyO/t/vj68v1cm4RKNl7oV/pTTHUU33ODyMBMsV5GdRZvZ1B/dV7GagDFWdpSQIZAAAAAMLtjaUvIgPRs3S1pbYMFAkyNtXOK5QpyzsSmN/AX3H2gSY12k4vPFJSyAA49tkLucbCmvcdfMT27UgYQ5OoD7vVJOrDzjWP+lgITaU+EGibOtDt+EvDUYkBAGATgEbzVH24na5QtyQUBdKQbZQxhEZt1FzONWop63JbtVZZeKSkkAEAAAAAADCHfQBIWmGUrvIeKwAAAABJRU5ErkJggg==',
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
  return event.method === 'HEAD' ? send(event, '') : DEFAULT_AVATAR_PNG;
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
      headOnly: event.method === 'HEAD',
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
      for(const [header,value]of Object.entries(error.headers))setResponseHeader(event,header,value);
      throw createError({
        statusCode: error.statusCode,
        statusMessage: error.message
      });
    }

    throw createError({statusCode:500,statusMessage:'Internal Server Error'});
  }
});
