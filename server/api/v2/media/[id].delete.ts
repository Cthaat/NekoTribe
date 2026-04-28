import { v2DeleteMedia } from '~/server/services/v2/media';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2DeleteMedia(event, connection, v2RouterNumber(event, 'id'))
);
