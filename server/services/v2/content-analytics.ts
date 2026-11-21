import { setResponseHeader, type H3Event } from 'h3';
import type { Connection } from 'oracledb';
import sql from '../../../specifications/requirements/content-analytics.json';
import { v2SafeRouterId } from '~/server/utils/router-id';
import { v2Auth, v2NotFound, v2Number, v2Ok, v2One, v2QueryNumber, v2Rows, v2String, v2Unprocessable } from '~/server/utils/v2';

function analyticsScope(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return { viewer_id: v2Auth(event).userId, target_id: v2SafeRouterId(event, 'id') };
}

export async function v2PostAnalytics(event: H3Event, connection: Connection): Promise<V2Response<V2PostAnalytics>> {
  const row = await v2One(connection, sql.post, analyticsScope(event));
  if (!row) v2NotFound('帖子不存在');
  if (v2Number(row.IS_OWNER) !== 1) v2Unprocessable('只能查看自己帖子的统计');
  if (!v2Number(row.STATS_POST_ID)) v2NotFound('帖子不存在');
  return v2Ok({
    post_id: v2Number(row.POST_ID), views_count: v2Number(row.VIEWS_COUNT), likes_count: v2Number(row.LIKES_COUNT),
    comments_count: v2Number(row.COMMENTS_COUNT), replies_count: v2Number(row.REPLIES_COUNT),
    retweets_count: v2Number(row.RETWEETS_COUNT), engagement_score: v2Number(row.ENGAGEMENT_SCORE),
    like_rate: v2Number(row.LIKE_RATE)
  });
}

export async function v2GetUserAnalytics(event: H3Event, connection: Connection): Promise<V2Response<V2UserAnalytics>> {
  const row = await v2One(connection, sql.summary, analyticsScope(event));
  if (!row) v2NotFound('用户不存在');
  return v2Ok({
    user_id: v2Number(row.USER_ID), total_posts: v2Number(row.TOTAL_POSTS), posts_this_week: v2Number(row.POSTS_THIS_WEEK),
    posts_this_month: v2Number(row.POSTS_THIS_MONTH), total_likes_received: v2Number(row.TOTAL_LIKES_RECEIVED),
    avg_likes_per_post: v2Number(row.AVG_LIKES_PER_POST), total_likes_given: v2Number(row.TOTAL_LIKES_GIVEN),
    total_comments_made: v2Number(row.TOTAL_COMMENTS_MADE), engagement_score: v2Number(row.ENGAGEMENT_SCORE)
  });
}

export async function v2GetUserDailyAnalytics(event: H3Event, connection: Connection): Promise<V2Response<V2UserDailyAnalytics[]>> {
  const scope = analyticsScope(event);
  if (scope.viewer_id !== scope.target_id) v2NotFound('用户不存在');
  const days = Math.trunc(Math.min(90, Math.max(7, v2QueryNumber(event, 'days', 14))));
  const rows = await v2Rows(connection, sql.daily, { ...scope, days });
  if (!rows.length) v2NotFound('用户不存在');
  return v2Ok(rows.map(row => ({
    day: v2String(row.DAY), posts_count: v2Number(row.POSTS_COUNT), likes_received: v2Number(row.LIKES_RECEIVED),
    comments_received: v2Number(row.COMMENTS_RECEIVED), retweets_received: v2Number(row.RETWEETS_RECEIVED),
    likes_given: v2Number(row.LIKES_GIVEN), comments_made: v2Number(row.COMMENTS_MADE),
    engagement_score: v2Number(row.ENGAGEMENT_SCORE)
  })), 'user daily analytics');
}
