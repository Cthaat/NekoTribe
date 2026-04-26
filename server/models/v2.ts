import type oracledb from 'oracledb';
import {
  v2Boolean,
  v2Count,
  v2DateString,
  v2JsonValue,
  v2NotFound,
  v2Number,
  v2One,
  v2Rows,
  v2String,
  v2StringOrNull,
  type V2DbRecord
} from '~/server/utils/v2';

function v2RelationObject(relation: string): V2Relationship {
  return {
    is_self: relation === 'self',
    is_following: ['following', 'mutual_follow'].includes(
      relation
    ),
    is_blocked: relation === 'blocked_by',
    is_blocking: relation === 'blocking',
    relation
  };
}

export function v2MapPublicUser(row: V2DbRecord): V2PublicUser {
  return {
    user_id: v2Number(row.USER_ID),
    username: v2String(row.USERNAME),
    display_name: v2String(row.DISPLAY_NAME),
    avatar_url: v2String(row.AVATAR_URL),
    bio: v2String(row.BIO),
    location: v2String(row.LOCATION),
    website: v2String(row.WEBSITE),
    is_verified: v2Number(row.IS_VERIFIED),
    followers_count: v2Number(row.FOLLOWERS_COUNT),
    following_count: v2Number(row.FOLLOWING_COUNT),
    posts_count: v2Number(row.POSTS_COUNT),
    likes_count: v2Number(row.LIKES_COUNT),
    relationship: v2RelationObject(v2String(row.RELATION, 'none'))
  };
}

export function v2MapSelfUser(row: V2DbRecord): V2SelfUser {
  return {
    ...v2MapPublicUser(row),
    email: v2String(row.EMAIL),
    phone: v2String(row.PHONE),
    birth_date: v2StringOrNull(row.BIRTH_DATE),
    email_verified_at: v2DateString(row.EMAIL_VERIFIED_AT),
    is_active: v2Number(row.IS_ACTIVE),
    status: v2String(row.STATUS),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2GetPublicUser(
  connection: oracledb.Connection,
  viewerId: number,
  userId: number
): Promise<V2PublicUser | null> {
  const row = await v2One(
    connection,
    `
    SELECT
      user_id,
      username,
      avatar_url,
      display_name,
      bio,
      location,
      website,
      is_verified,
      followers_count,
      following_count,
      posts_count,
      likes_count,
      fn_get_user_relationship(:viewer_id, user_id) AS relation
    FROM v_user_profile_public
    WHERE user_id = :user_id
      AND is_active = 1
    `,
    { viewer_id: viewerId, user_id: userId }
  );
  return row ? v2MapPublicUser(row) : null;
}

export async function v2RequirePublicUser(
  connection: oracledb.Connection,
  viewerId: number,
  userId: number
): Promise<V2PublicUser> {
  const user = await v2GetPublicUser(
    connection,
    viewerId,
    userId
  );
  if (!user) v2NotFound('用户不存在');
  return user;
}

export async function v2GetSelfUser(
  connection: oracledb.Connection,
  userId: number
): Promise<V2SelfUser | null> {
  const row = await v2One(
    connection,
    `
    SELECT
      user_id,
      email,
      username,
      avatar_url,
      display_name,
      bio,
      location,
      website,
      phone,
      TO_CHAR(birth_date, 'YYYY-MM-DD') AS birth_date,
      email_verified_at,
      is_verified,
      is_active,
      status,
      followers_count,
      following_count,
      posts_count,
      likes_count,
      bookmarks_count,
      comments_count,
      created_at,
      updated_at,
      fn_get_user_relationship(:viewer_id, user_id) AS relation
    FROM v_user_profile_self
    WHERE user_id = :user_id
    `,
    { viewer_id: userId, user_id: userId }
  );
  return row ? v2MapSelfUser(row) : null;
}

export async function v2RequireSelfUser(
  connection: oracledb.Connection,
  userId: number
): Promise<V2SelfUser> {
  const user = await v2GetSelfUser(connection, userId);
  if (!user) v2NotFound('用户不存在');
  return user;
}

export async function v2ListPublicUsersByIds(
  connection: oracledb.Connection,
  viewerId: number,
  userIds: number[]
): Promise<V2PublicUser[]> {
  if (userIds.length === 0) return [];
  const binds: Record<string, number> = { viewer_id: viewerId };
  const placeholders = userIds.map((id, index) => {
    const key = `id_${index}`;
    binds[key] = id;
    return `:${key}`;
  });
  const rows = await v2Rows(
    connection,
    `
    SELECT
      user_id,
      username,
      avatar_url,
      display_name,
      bio,
      location,
      website,
      is_verified,
      followers_count,
      following_count,
      posts_count,
      likes_count,
      fn_get_user_relationship(:viewer_id, user_id) AS relation
    FROM v_user_profile_public
    WHERE user_id IN (${placeholders.join(', ')})
    `,
    binds
  );
  return rows.map(v2MapPublicUser);
}

export function v2MapMedia(row: V2DbRecord): V2MediaAsset {
  return {
    media_id: v2Number(row.MEDIA_ID),
    media_type: v2String(row.MEDIA_TYPE),
    file_name: v2String(row.FILE_NAME),
    public_url: v2String(row.PUBLIC_URL),
    file_size: v2Number(row.FILE_SIZE),
    mime_type: v2String(row.MIME_TYPE),
    width: row.WIDTH === null ? null : v2Number(row.WIDTH),
    height: row.HEIGHT === null ? null : v2Number(row.HEIGHT),
    duration:
      row.DURATION === null ? null : v2Number(row.DURATION),
    thumbnail_url: v2StringOrNull(row.THUMBNAIL_URL),
    alt_text: v2StringOrNull(row.ALT_TEXT),
    status: v2String(row.STATUS),
    created_at: v2DateString(row.CREATED_AT) || ''
  };
}

export async function v2GetPostMedia(
  connection: oracledb.Connection,
  postId: number
): Promise<V2MediaAsset[]> {
  const rows = await v2Rows(
    connection,
    `
    SELECT
      ma.media_id,
      ma.media_type,
      ma.file_name,
      ma.public_url,
      ma.file_size,
      ma.mime_type,
      ma.width,
      ma.height,
      ma.duration,
      ma.thumbnail_url,
      ma.alt_text,
      ma.status,
      ma.created_at
    FROM n_post_media pm
    JOIN n_media_assets ma ON ma.media_id = pm.media_id
    WHERE pm.post_id = :post_id
    ORDER BY pm.sort_order
    `,
    { post_id: postId }
  );
  return rows.map(v2MapMedia);
}

export async function v2GetPostTags(
  connection: oracledb.Connection,
  postId: number
): Promise<string[]> {
  const rows = await v2Rows(
    connection,
    `
    SELECT t.name
    FROM n_post_tags pt
    JOIN n_tags t ON t.tag_id = pt.tag_id
    WHERE pt.post_id = :post_id
    ORDER BY t.name
    `,
    { post_id: postId }
  );
  return rows.map(row => v2String(row.NAME));
}

export async function v2GetPostMentions(
  connection: oracledb.Connection,
  viewerId: number,
  postId: number
): Promise<V2PublicUser[]> {
  const rows = await v2Rows(
    connection,
    `
    SELECT
      u.user_id,
      u.username,
      u.avatar_url,
      u.display_name,
      u.bio,
      u.location,
      u.website,
      u.is_verified,
      u.followers_count,
      u.following_count,
      u.posts_count,
      u.likes_count,
      fn_get_user_relationship(:viewer_id, u.user_id) AS relation
    FROM n_post_mentions pm
    JOIN v_user_profile_public u
      ON u.user_id = pm.mentioned_user_id
    WHERE pm.post_id = :post_id
    ORDER BY u.username
    `,
    { viewer_id: viewerId, post_id: postId }
  );
  return rows.map(v2MapPublicUser);
}

export async function v2MapPost(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2Post> {
  const postId = v2Number(row.POST_ID);
  const authorId = v2Number(row.AUTHOR_ID);
  const author = await v2RequirePublicUser(
    connection,
    viewerId,
    authorId
  );

  return {
    post_id: postId,
    author,
    content: v2String(row.CONTENT),
    post_type: v2String(row.POST_TYPE),
    visibility: v2String(row.VISIBILITY),
    language: v2String(row.LANGUAGE),
    location: v2String(row.LOCATION),
    reply_to_post_id: v2NullableNumber(row.REPLY_TO_POST_ID),
    repost_of_post_id: v2NullableNumber(row.REPOST_OF_POST_ID),
    quoted_post_id: v2NullableNumber(row.QUOTED_POST_ID),
    media: await v2GetPostMedia(connection, postId),
    tags: await v2GetPostTags(connection, postId),
    mentions: await v2GetPostMentions(
      connection,
      viewerId,
      postId
    ),
    stats: {
      likes_count: v2Number(row.LIKES_COUNT),
      comments_count: v2Number(row.COMMENTS_COUNT),
      replies_count: v2Number(row.REPLIES_COUNT),
      retweets_count: v2Number(row.RETWEETS_COUNT),
      views_count: v2Number(row.VIEWS_COUNT),
      engagement_score: v2Number(row.ENGAGEMENT_SCORE)
    },
    viewer_state: {
      is_liked: v2Boolean(row.IS_LIKED),
      is_bookmarked: v2Boolean(row.IS_BOOKMARKED),
      can_delete: authorId === viewerId
    },
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export function v2PostSelectSql(extraWhere: string): string {
  return `
    SELECT *
    FROM (
      SELECT
        v.post_id,
        v.author_id,
        DBMS_LOB.SUBSTR(v.content, 4000, 1) AS content,
        v.post_type,
        v.reply_to_post_id,
        v.repost_of_post_id,
        v.quoted_post_id,
        v.visibility,
        v.language,
        v.location,
        v.created_at,
        v.updated_at,
        v.likes_count,
        v.comments_count,
        v.replies_count,
        v.retweets_count,
        v.views_count,
        v.engagement_score,
        CASE WHEN EXISTS (
          SELECT 1
          FROM n_post_likes pl
          WHERE pl.post_id = v.post_id
            AND pl.user_id = :viewer_id
        ) THEN 1 ELSE 0 END AS is_liked,
        CASE WHEN EXISTS (
          SELECT 1
          FROM n_post_bookmarks pb
          WHERE pb.post_id = v.post_id
            AND pb.user_id = :viewer_id
        ) THEN 1 ELSE 0 END AS is_bookmarked,
        ROW_NUMBER() OVER (__ORDER_BY__) AS rn
      FROM v_post_feed_item v
      WHERE fn_can_view_post(:viewer_id, v.post_id) = 1
      ${extraWhere}
    )
    WHERE rn BETWEEN :start_row AND :end_row
  `;
}

export function v2PostCountSql(extraWhere: string): string {
  return `
    SELECT COUNT(*) AS total
    FROM v_post_feed_item v
    WHERE fn_can_view_post(:viewer_id, v.post_id) = 1
    ${extraWhere}
  `;
}

export function v2SortOrder(sort: string): string {
  if (sort === 'oldest') return 'ORDER BY v.created_at ASC';
  if (sort === 'popular') {
    return 'ORDER BY v.engagement_score DESC, v.created_at DESC';
  }
  return 'ORDER BY v.created_at DESC';
}

function v2NullableNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') {
    return null;
  }
  return v2Number(value);
}

export async function v2GetPostById(
  connection: oracledb.Connection,
  viewerId: number,
  postId: number
): Promise<V2Post | null> {
  const row = await v2One(
    connection,
    v2PostSelectSql('AND v.post_id = :post_id').replace(
      '__ORDER_BY__',
      'ORDER BY v.created_at DESC'
    ),
    {
      viewer_id: viewerId,
      post_id: postId,
      start_row: 1,
      end_row: 1
    }
  );
  return row ? await v2MapPost(connection, viewerId, row) : null;
}

export async function v2RequirePostById(
  connection: oracledb.Connection,
  viewerId: number,
  postId: number
): Promise<V2Post> {
  const post = await v2GetPostById(connection, viewerId, postId);
  if (!post) v2NotFound('帖子不存在');
  return post;
}

export async function v2MapComment(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2Comment> {
  const authorId = v2Number(row.USER_ID);
  return {
    comment_id: v2Number(row.COMMENT_ID),
    post_id: v2Number(row.POST_ID),
    author: await v2RequirePublicUser(
      connection,
      viewerId,
      authorId
    ),
    parent_comment_id: v2NullableNumber(row.PARENT_COMMENT_ID),
    root_comment_id: v2NullableNumber(row.ROOT_COMMENT_ID),
    content: v2String(row.CONTENT),
    stats: {
      likes_count: v2Number(row.LIKES_COUNT),
      replies_count: v2Number(row.REPLIES_COUNT)
    },
    viewer_state: {
      is_liked: v2Boolean(row.IS_LIKED),
      can_delete: authorId === viewerId
    },
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function v2CommentCount(
  connection: oracledb.Connection,
  postId: number
): Promise<number> {
  return await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM v_post_comment_list_item
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
}

export function v2MapNotification(
  row: V2DbRecord,
  actor: V2PublicUser | null
): V2Notification {
  return {
    notification_id: v2Number(row.NOTIFICATION_ID),
    type: v2String(row.TYPE),
    title: v2String(row.TITLE),
    message: v2String(row.MESSAGE),
    resource_type: v2StringOrNull(row.RESOURCE_TYPE),
    resource_id: v2NullableNumber(row.RESOURCE_ID),
    priority: v2String(row.PRIORITY),
    is_read: v2Number(row.IS_READ),
    read_at: v2DateString(row.READ_AT),
    deleted_at: v2DateString(row.DELETED_AT),
    actor,
    metadata: v2JsonValue(row.METADATA_JSON),
    created_at: v2DateString(row.CREATED_AT) || ''
  };
}

export async function v2MapGroup(
  connection: oracledb.Connection,
  viewerId: number,
  row: V2DbRecord
): Promise<V2Group> {
  const groupId = v2Number(row.GROUP_ID);
  const ownerId = v2Number(row.OWNER_ID);
  const membership = await v2One(
    connection,
    `
    SELECT role, status, joined_at
    FROM n_group_members
    WHERE group_id = :group_id
      AND user_id = :user_id
    `,
    { group_id: groupId, user_id: viewerId }
  );

  return {
    group_id: groupId,
    name: v2String(row.GROUP_NAME ?? row.NAME),
    slug: v2String(row.SLUG),
    description: v2String(row.DESCRIPTION),
    avatar_url: v2StringOrNull(
      row.GROUP_AVATAR_URL ?? row.AVATAR_URL
    ),
    cover_url: v2StringOrNull(row.COVER_URL),
    owner: await v2RequirePublicUser(
      connection,
      viewerId,
      ownerId
    ),
    privacy: v2String(row.PRIVACY),
    privacy_desc: v2String(row.PRIVACY_DESC),
    join_approval: v2Boolean(row.JOIN_APPROVAL),
    post_permission: v2String(row.POST_PERMISSION),
    member_count: v2Number(row.MEMBER_COUNT),
    post_count: v2Number(row.POST_COUNT),
    is_active: v2Number(row.IS_ACTIVE),
    membership: {
      is_member: Boolean(membership),
      role: membership ? v2String(rowOrNull(membership.ROLE)) : null,
      status: membership
        ? v2String(rowOrNull(membership.STATUS))
        : null,
      joined_at: membership
        ? v2DateString(membership.JOINED_AT)
        : null
    },
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

function rowOrNull(value: unknown): unknown {
  return value ?? null;
}

export async function v2RequireGroup(
  connection: oracledb.Connection,
  viewerId: number,
  groupId: number
): Promise<V2Group> {
  const row = await v2One(
    connection,
    `
    SELECT *
    FROM v_group_details
    WHERE group_id = :group_id
      AND is_deleted = 0
    `,
    { group_id: groupId }
  );
  if (!row) v2NotFound('群组不存在');
  return await v2MapGroup(connection, viewerId, row);
}

export function v2MediaUrlArray(value: unknown): string[] {
  const text = v2String(value);
  if (!text) return [];
  return text
    .split(',')
    .map(item => item.trim())
    .filter(item => item.length > 0);
}
