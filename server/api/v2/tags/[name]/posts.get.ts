import { v2ListPosts } from '~/server/services/v2/posts';
import { getRouterParam } from 'h3';
import {
  defineV2Handler,
  v2BadRequest
} from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry((event, connection) => {
  const name = getRouterParam(event, 'name', { decode: true });
  if (!name) v2BadRequest('name 参数错误');
  return v2ListPosts(event, connection, {
    mode: 'tag',
    tag_name: name
  });
}));
