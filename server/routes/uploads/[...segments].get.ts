import { getRouterParam, setResponseStatus } from 'h3';

export default defineEventHandler(event => {
  setResponseStatus(
    event,
    410,
    'Legacy uploads path removed'
  );

  return {
    code: 410,
    message:
      'Legacy /uploads path removed. Public files are served from /storage.',
    data: {
      requested_path: `/uploads/${getRouterParam(event, 'segments') || ''}`,
      storage_base: '/storage'
    },
    meta: null
  };
});
