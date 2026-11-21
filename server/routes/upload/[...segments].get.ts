import {
  defineEventHandler,
  getRouterParam,
  setResponseHeader,
  setResponseStatus
} from 'h3';

export default defineEventHandler(event => {
  setResponseHeader(event, 'Cache-Control', 'no-store');
  setResponseStatus(
    event,
    410,
    'Legacy upload path removed'
  );

  return {
    code: 410,
    message:
      'Legacy /upload path removed. Public files are served from /storage.',
    data: {
      requested_path: `/upload/${getRouterParam(event, 'segments') || ''}`,
      storage_base: '/storage'
    },
    meta: null
  };
});
