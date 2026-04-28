import { defineEventHandler, setResponseStatus } from 'h3';

export default defineEventHandler(event => {
  setResponseStatus(event, 404, 'API route not found');

  return {
    code: 40404,
    message: 'API route not found',
    data: null,
    meta: null
  } satisfies V2Response<null>;
});
