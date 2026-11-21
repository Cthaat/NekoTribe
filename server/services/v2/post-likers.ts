import { setResponseHeader, type H3Event } from 'h3';
import type { Connection } from 'oracledb';
import statements from '../../../specifications/requirements/post-likers.json';
import { v2MapPublicUser } from '~/server/models/v2';
import { v2SafeRouterId } from '~/server/utils/router-id';
import { v2Auth, v2NotFound, v2Number, v2Ok, v2Page, v2PageMeta, v2Rows } from '~/server/utils/v2';

export async function v2PostLikesUsers(event: H3Event, connection: Connection): Promise<V2Response<V2PublicUser[]>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const postId = v2SafeRouterId(event, 'id');
  const page = v2Page(event);
  const rows = await v2Rows(connection, statements.list, {
    viewer_id: userId, post_id: postId, start_row: page.start, end_row: page.end
  });
  const first = rows[0];
  if (!first) v2NotFound('帖子不存在');
  return v2Ok(rows.filter(row => v2Number(row.USER_ID) > 0).map(v2MapPublicUser), 'success',
    v2PageMeta(page.page, page.page_size, v2Number(first.TOTAL)));
}
