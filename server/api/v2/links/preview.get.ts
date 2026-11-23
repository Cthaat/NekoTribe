import { defineEventHandler, getQuery } from 'h3';
import { previewLink } from '~/server/services/v2/link-preview';
import { v2Auth, v2Ok } from '~/server/utils/v2';

export default defineEventHandler(async (event) => {
  v2Auth(event);
  return v2Ok({ preview: await previewLink(getQuery(event).url) });
});
