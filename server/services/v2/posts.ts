/// <reference path="../../types/v2.d.ts" />

import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2Boolean,
  v2Count,
  v2DateString,
  v2Execute,
  v2NextId,
  v2NotFound,
  v2Null,
  v2Number,
  v2NumberArray,
  v2Ok,
  v2One,
  v2Page,
  v2PageMeta,
  v2QueryString,
  v2RequiredNumber,
  v2RequiredString,
  v2Rows,
  v2String,
  v2StringArray,
  v2Unprocessable
} from '~/server/utils/v2';
import {
  v2CommentCount,
  v2MapComment,
  v2MapPost,
  v2MapPublicUser,
  v2PostCountSql,
  v2PostSelectSql,
  v2RequirePostById,
  v2SortOrder
} from '~/server/models/v2';
import { v2CreateNotification } from './notifications';

type V2PostListMode =
  | 'all'
  | 'trending'
  | 'user'
  | 'me'
  | 'bookmarks'
  | 'tag'
  | 'replies'
  | 'retweets';

interface V2PostListOptions {
  mode: V2PostListMode;
  user_id?: number;
  post_id?: number;
  tag_name?: string;
}

interface V2UpdatePostPayload {
  content?: string;
  visibility?: V2CreatePostPayload['visibility'];
  language?: string;
  location?: string | null;
  media_ids?: number[];
  tag_names?: string[];
  mention_user_ids?: number[];
}

async function v2UserDisplayName(
  connection: oracledb.Connection,
  userId: number
): Promise<string> {
  const row = await v2One(
    connection,
    `
    SELECT COALESCE(display_name, username) AS name
    FROM n_users
    WHERE user_id = :user_id
    `,
    { user_id: userId }
  );
  return v2String(row?.NAME, '有人');
}

async function v2PostAuthorId(
  connection: oracledb.Connection,
  postId: number | null | undefined
): Promise<number | null> {
  if (!postId) return null;
  const row = await v2One(
    connection,
    `
    SELECT author_id
    FROM n_posts
    WHERE post_id = :post_id
      AND is_deleted = 0
    `,
    { post_id: postId }
  );
  return row ? v2Number(row.AUTHOR_ID) : null;
}

async function v2CommentAuthorId(
  connection: oracledb.Connection,
  commentId: number | null | undefined
): Promise<number | null> {
  if (!commentId) return null;
  const row = await v2One(
    connection,
    `
    SELECT user_id
    FROM n_comments
    WHERE comment_id = :comment_id
      AND is_deleted = 0
    `,
    { comment_id: commentId }
  );
  return row ? v2Number(row.USER_ID) : null;
}

function v2PostVisibility(value: string): string {
  if (
    value === 'public' ||
    value === 'followers' ||
    value === 'mentioned' ||
    value === 'private'
  ) {
    return value;
  }
  v2BadRequest('visibility 参数错误');
}

function v2PostLanguage(value: string): string {
  const normalized = value.trim().toLowerCase();
  if (!normalized) return 'zh';
  if (/^[a-z]{2}(-[a-z0-9]{2,7})?$/.test(normalized)) {
    return normalized.slice(0, 10);
  }
  v2BadRequest('language 参数错误');
}

function v2PostType(payload: V2CreatePostPayload): string {
  const refs = [
    payload.reply_to_post_id,
    payload.repost_of_post_id,
    payload.quoted_post_id
  ].filter(value => value !== undefined && value !== null);
  if (refs.length > 1) v2BadRequest('引用字段只能传一个');
  if (payload.reply_to_post_id) return 'reply';
  if (payload.repost_of_post_id) return 'repost';
  if (payload.quoted_post_id) return 'quote';
  return 'post';
}

async function v2ReadCreatePostPayload(
  event: H3Event
): Promise<V2CreatePostPayload> {
  const body = await v2Body(event);
  return {
    content: v2String(body.content),
    visibility: v2PostVisibility(
      v2String(body.visibility, 'public')
    ) as V2CreatePostPayload['visibility'],
    media_ids: v2NumberArray(
      v2BodyField(body, 'media_ids', 'mediaIds')
    ),
    tag_names: v2StringArray(
      v2BodyField(body, 'tag_names', 'tagNames')
    ),
    mention_user_ids: v2NumberArray(
      v2BodyField(
        body,
        'mention_user_ids',
        'mentionUserIds'
      )
    ),
    reply_to_post_id: v2RequiredOptionalNumber(
      v2BodyField(
        body,
        'reply_to_post_id',
        'replyToPostId'
      )
    ),
    repost_of_post_id: v2RequiredOptionalNumber(
      v2BodyField(
        body,
        'repost_of_post_id',
        'repostOfPostId'
      )
    ),
    quoted_post_id: v2RequiredOptionalNumber(
      v2BodyField(
        body,
        'quoted_post_id',
        'quotedPostId'
      )
    ),
    location: v2String(body.location)
  };
}

function v2BodyField(
  body: Record<string, unknown>,
  primaryKey: string,
  fallbackKey: string
): unknown {
  return Object.prototype.hasOwnProperty.call(
    body,
    primaryKey
  )
    ? body[primaryKey]
    : body[fallbackKey];
}

function v2HasBodyField(
  body: Record<string, unknown>,
  primaryKey: string,
  fallbackKey?: string
): boolean {
  return (
    Object.prototype.hasOwnProperty.call(body, primaryKey) ||
    (fallbackKey
      ? Object.prototype.hasOwnProperty.call(body, fallbackKey)
      : false)
  );
}

function v2RequiredOptionalNumber(
  value: unknown
): number | null | undefined {
  if (value === undefined) return undefined;
  if (value === null || value === '') return null;
  return v2RequiredNumber(value);
}

async function v2ReadUpdatePostPayload(
  event: H3Event
): Promise<V2UpdatePostPayload> {
  const body = await v2Body(event);
  const payload: V2UpdatePostPayload = {};

  if (v2HasBodyField(body, 'content')) {
    payload.content = v2String(body.content);
  }
  if (v2HasBodyField(body, 'visibility')) {
    payload.visibility = v2PostVisibility(
      v2String(body.visibility)
    ) as V2CreatePostPayload['visibility'];
  }
  if (v2HasBodyField(body, 'language')) {
    payload.language = v2PostLanguage(v2String(body.language));
  }
  if (v2HasBodyField(body, 'location')) {
    payload.location = v2String(body.location) || null;
  }
  if (v2HasBodyField(body, 'media_ids', 'mediaIds')) {
    payload.media_ids = v2NumberArray(
      v2BodyField(body, 'media_ids', 'mediaIds')
    );
  }
  if (v2HasBodyField(body, 'tag_names', 'tagNames')) {
    payload.tag_names = v2StringArray(
      v2BodyField(body, 'tag_names', 'tagNames')
    );
  }
  if (
    v2HasBodyField(
      body,
      'mention_user_ids',
      'mentionUserIds'
    )
  ) {
    payload.mention_user_ids = v2NumberArray(
      v2BodyField(
        body,
        'mention_user_ids',
        'mentionUserIds'
      )
    );
  }

  return payload;
}

export async function v2ListPosts(
  event: H3Event,
  connection: oracledb.Connection,
  options: V2PostListOptions = { mode: 'all' }
): Promise<V2Response<V2Post[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const sort =
    options.mode === 'trending'
      ? 'popular'
      : v2QueryString(event, 'sort', 'newest');
  const timeline = v2QueryString(event, 'timeline', 'home');
  const q = v2QueryString(event, 'q').trim().toLowerCase();
  const binds: Record<string, string | number | null> = {
    viewer_id: auth.userId
  };
  const where: string[] = [];

  if (options.mode === 'user' && options.user_id) {
    where.push('AND v.author_id = :author_id');
    binds.author_id = options.user_id;
  }
  if (options.mode === 'me') {
    where.push('AND v.author_id = :author_id');
    binds.author_id = auth.userId;
  }
  if (options.mode === 'bookmarks') {
    where.push(`
      AND EXISTS (
        SELECT 1
        FROM n_post_bookmarks b
        WHERE b.post_id = v.post_id
          AND b.user_id = :viewer_id
      )
    `);
  }
  if (options.mode === 'tag' && options.tag_name) {
    where.push(`
      AND EXISTS (
        SELECT 1
        FROM n_post_tags pt
        JOIN n_tags t ON t.tag_id = pt.tag_id
        WHERE pt.post_id = v.post_id
          AND t.name_lower = LOWER(:tag_name)
      )
    `);
    binds.tag_name = options.tag_name;
  }
  if (options.mode === 'replies' && options.post_id) {
    where.push('AND v.reply_to_post_id = :target_post_id');
    binds.target_post_id = options.post_id;
  }
  if (options.mode === 'retweets' && options.post_id) {
    where.push('AND v.repost_of_post_id = :target_post_id');
    binds.target_post_id = options.post_id;
  }
  if (timeline === 'mentions') {
    where.push(`
      AND EXISTS (
        SELECT 1
        FROM n_post_mentions pm
        WHERE pm.post_id = v.post_id
          AND pm.mentioned_user_id = :viewer_id
      )
    `);
  }
  if (q) {
    where.push(
      'AND LOWER(DBMS_LOB.SUBSTR(v.content, 4000, 1)) LIKE :q'
    );
    binds.q = `%${q}%`;
  }

  const extraWhere = where.join('\n');
  const total = await v2Count(
    connection,
    v2PostCountSql(extraWhere),
    binds
  );
  const rows = await v2Rows(
    connection,
    v2PostSelectSql(extraWhere).replace(
      '__ORDER_BY__',
      v2SortOrder(sort)
    ),
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  const posts = await Promise.all(
    rows.map(row => v2MapPost(connection, auth.userId, row))
  );
  return v2Ok(
    posts,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreatePost(
  event: H3Event,
  connection: oracledb.Connection,
  override?: Partial<V2CreatePostPayload>
): Promise<V2Response<V2Post>> {
  const payload = {
    ...(await v2ReadCreatePostPayload(event)),
    ...override
  };
  return await v2CreatePostFromPayload(
    event,
    connection,
    payload
  );
}

async function v2CreatePostFromPayload(
  event: H3Event,
  connection: oracledb.Connection,
  payload: V2CreatePostPayload
): Promise<V2Response<V2Post>> {
  const auth = v2Auth(event);
  const postType = v2PostType(payload);
  if (
    postType !== 'repost' &&
    !v2String(payload.content).trim() &&
    (payload.media_ids?.length ?? 0) === 0
  ) {
    v2BadRequest('content 不能为空');
  }

  const postId = await v2NextId(connection, 'seq_post_id');
  await v2Execute(
    connection,
    `
    INSERT INTO n_posts (
      post_id,
      author_id,
      content,
      post_type,
      reply_to_post_id,
      repost_of_post_id,
      quoted_post_id,
      visibility,
      language,
      location
    ) VALUES (
      :post_id,
      :author_id,
      :content,
      :post_type,
      :reply_to_post_id,
      :repost_of_post_id,
      :quoted_post_id,
      :visibility,
      'zh',
      :location
    )
    `,
    {
      post_id: postId,
      author_id: auth.userId,
      content: payload.content || null,
      post_type: postType,
      reply_to_post_id: payload.reply_to_post_id ?? null,
      repost_of_post_id: payload.repost_of_post_id ?? null,
      quoted_post_id: payload.quoted_post_id ?? null,
      visibility: payload.visibility || 'public',
      location: payload.location || null
    }
  );

  await v2AttachPostMedia(
    connection,
    postId,
    auth.userId,
    payload.media_ids ?? []
  );
  await v2AttachPostTags(
    connection,
    postId,
    payload.tag_names ?? []
  );
  await v2AttachPostMentions(
    connection,
    postId,
    payload.mention_user_ids ?? []
  );
  await v2NotifyPostCreated(
    connection,
    auth.userId,
    postId,
    postType,
    payload
  );

  return v2Ok(
    await v2RequirePostById(
      connection,
      auth.userId,
      postId
    ),
    postType === 'repost'
      ? 'retweet created'
      : 'post created'
  );
}

export async function v2UpdatePost(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2Post>> {
  const auth = v2Auth(event);
  const payload = await v2ReadUpdatePostPayload(event);
  const row = await v2One(
    connection,
    `
    SELECT
      author_id,
      is_deleted,
      post_type,
      DBMS_LOB.SUBSTR(content, 4000, 1) AS content
    FROM n_posts
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  if (!row || v2Boolean(row.IS_DELETED))
    v2NotFound('帖子不存在');
  if (v2Number(row.AUTHOR_ID) !== auth.userId) {
    v2Unprocessable('只能修改自己的帖子');
  }

  const currentContent = v2String(row.CONTENT);
  const nextContent =
    payload.content !== undefined
      ? payload.content
      : currentContent;
  const nextMediaCount =
    payload.media_ids !== undefined
      ? [...new Set(payload.media_ids)].slice(0, 4).length
      : await v2Count(
          connection,
          `
          SELECT COUNT(*) AS total
          FROM n_post_media
          WHERE post_id = :post_id
          `,
          { post_id: postId }
        );
  if (
    v2String(row.POST_TYPE) !== 'repost' &&
    !nextContent.trim() &&
    nextMediaCount === 0
  ) {
    v2BadRequest('content 不能为空');
  }

  const updateFields: string[] = [];
  const binds: Record<string, string | number | null> = {
    post_id: postId
  };
  if (payload.content !== undefined) {
    updateFields.push('content = :content');
    binds.content = payload.content || null;
  }
  if (payload.visibility !== undefined) {
    updateFields.push('visibility = :visibility');
    binds.visibility = payload.visibility;
  }
  if (payload.language !== undefined) {
    updateFields.push('language = :language');
    binds.language = payload.language;
  }
  if (payload.location !== undefined) {
    updateFields.push('location = :location');
    binds.location = payload.location || null;
  }

  const hasRelationChanges =
    payload.media_ids !== undefined ||
    payload.tag_names !== undefined ||
    payload.mention_user_ids !== undefined;

  if (updateFields.length > 0 || hasRelationChanges) {
    await v2Execute(
      connection,
      `
      UPDATE n_posts
      SET ${[
        ...updateFields,
        'updated_at = CURRENT_TIMESTAMP'
      ].join(',\n          ')}
      WHERE post_id = :post_id
      `,
      binds
    );
  }

  if (payload.media_ids !== undefined) {
    const mediaIds = [...new Set(payload.media_ids)].slice(0, 4);
    const usableMediaCount =
      mediaIds.length === 0
        ? 0
        : await v2Count(
            connection,
            `
            SELECT COUNT(*) AS total
            FROM n_media_assets
            WHERE owner_user_id = :user_id
              AND status IN ('uploaded', 'processing', 'ready')
              AND media_id IN (${mediaIds
                .map((_, index) => `:media_id_${index}`)
                .join(', ')})
            `,
            mediaIds.reduce<Record<string, number>>(
              (mediaBinds, mediaId, index) => {
                mediaBinds[`media_id_${index}`] = mediaId;
                return mediaBinds;
              },
              { user_id: auth.userId }
            )
          );
    if (usableMediaCount !== mediaIds.length) {
      v2BadRequest('附件不存在或无权使用');
    }
    await v2Execute(
      connection,
      `
      DELETE FROM n_post_media
      WHERE post_id = :post_id
      `,
      { post_id: postId }
    );
    await v2AttachPostMedia(
      connection,
      postId,
      auth.userId,
      mediaIds
    );
  }

  if (payload.tag_names !== undefined) {
    await v2Execute(
      connection,
      `
      DELETE FROM n_post_tags
      WHERE post_id = :post_id
      `,
      { post_id: postId }
    );
    await v2AttachPostTags(
      connection,
      postId,
      payload.tag_names
    );
  }

  if (payload.mention_user_ids !== undefined) {
    await v2Execute(
      connection,
      `
      DELETE FROM n_post_mentions
      WHERE post_id = :post_id
      `,
      { post_id: postId }
    );
    await v2AttachPostMentions(
      connection,
      postId,
      payload.mention_user_ids
    );
  }

  return v2Ok(
    await v2RequirePostById(
      connection,
      auth.userId,
      postId
    ),
    'post updated'
  );
}

async function v2AttachPostMedia(
  connection: oracledb.Connection,
  postId: number,
  userId: number,
  mediaIds: number[]
): Promise<void> {
  let sortOrder = 1;
  for (const mediaId of mediaIds.slice(0, 4)) {
    await v2Execute(
      connection,
      `
      INSERT INTO n_post_media (post_id, media_id, sort_order)
      SELECT :post_id, media_id, :sort_order
      FROM n_media_assets
      WHERE media_id = :media_id
        AND owner_user_id = :user_id
        AND status IN ('uploaded', 'processing', 'ready')
      `,
      {
        post_id: postId,
        media_id: mediaId,
        user_id: userId,
        sort_order: sortOrder
      }
    );
    sortOrder += 1;
  }
}

async function v2AttachPostTags(
  connection: oracledb.Connection,
  postId: number,
  tagNames: string[]
): Promise<void> {
  const uniqueTags = [
    ...new Set(
      tagNames
        .map(tag => tag.replace(/^#/, '').trim())
        .filter(Boolean)
    )
  ].slice(0, 20);
  for (const tag of uniqueTags) {
    await v2Execute(
      connection,
      `
      MERGE INTO n_tags t
      USING (
        SELECT :name AS name, LOWER(:name) AS name_lower
        FROM dual
      ) src
      ON (t.name_lower = src.name_lower)
      WHEN NOT MATCHED THEN
        INSERT (tag_id, name, name_lower)
        VALUES (seq_tag_id.NEXTVAL, src.name, src.name_lower)
      `,
      { name: tag }
    );
    await v2Execute(
      connection,
      `
      INSERT INTO n_post_tags (post_id, tag_id)
      SELECT :post_id, tag_id
      FROM n_tags
      WHERE name_lower = LOWER(:name)
        AND NOT EXISTS (
          SELECT 1
          FROM n_post_tags
          WHERE post_id = :post_id
            AND tag_id = n_tags.tag_id
        )
      `,
      { post_id: postId, name: tag }
    );
  }
}

async function v2AttachPostMentions(
  connection: oracledb.Connection,
  postId: number,
  userIds: number[]
): Promise<void> {
  for (const userId of [...new Set(userIds)].slice(0, 50)) {
    await v2Execute(
      connection,
      `
      INSERT INTO n_post_mentions (post_id, mentioned_user_id)
      SELECT :post_id, user_id
      FROM n_users
      WHERE user_id = :user_id
        AND NOT EXISTS (
          SELECT 1
          FROM n_post_mentions
          WHERE post_id = :post_id
            AND mentioned_user_id = :user_id
        )
      `,
      { post_id: postId, user_id: userId }
    );
  }
}

async function v2NotifyPostCreated(
  connection: oracledb.Connection,
  actorId: number,
  postId: number,
  postType: string,
  payload: V2CreatePostPayload
): Promise<void> {
  const actorName = await v2UserDisplayName(connection, actorId);

  if (postType === 'reply') {
    const targetUserId = await v2PostAuthorId(
      connection,
      payload.reply_to_post_id
    );
    if (targetUserId) {
      await v2CreateNotification(connection, {
        userId: targetUserId,
        actorId,
        type: 'comment',
        title: `${actorName} 回复了你的推文`,
        message: '你的推文收到了一条新回复。',
        resourceType: 'post',
        resourceId: postId,
        metadata: {
          source_post_id: payload.reply_to_post_id ?? null,
          event: 'post_reply'
        }
      });
    }
  }

  if (postType === 'repost') {
    const targetUserId = await v2PostAuthorId(
      connection,
      payload.repost_of_post_id
    );
    if (targetUserId) {
      await v2CreateNotification(connection, {
        userId: targetUserId,
        actorId,
        type: 'retweet',
        title: `${actorName} 转发了你的推文`,
        message: '你的推文被转发了。',
        resourceType: 'post',
        resourceId: postId,
        metadata: {
          source_post_id: payload.repost_of_post_id ?? null,
          event: 'post_repost'
        }
      });
    }
  }

  if (postType === 'quote') {
    const targetUserId = await v2PostAuthorId(
      connection,
      payload.quoted_post_id
    );
    if (targetUserId) {
      await v2CreateNotification(connection, {
        userId: targetUserId,
        actorId,
        type: 'retweet',
        title: `${actorName} 引用了你的推文`,
        message: '你的推文被引用了。',
        resourceType: 'post',
        resourceId: postId,
        metadata: {
          source_post_id: payload.quoted_post_id ?? null,
          event: 'post_quote'
        }
      });
    }
  }

  for (const mentionedUserId of [
    ...new Set(payload.mention_user_ids ?? [])
  ]) {
    await v2CreateNotification(connection, {
      userId: mentionedUserId,
      actorId,
      type: 'mention',
      title: `${actorName} 提及了你`,
      message: '你在一条推文中被提及。',
      resourceType: 'post',
      resourceId: postId,
      metadata: {
        event: 'post_mention'
      }
    });
  }
}

async function v2NotifyCommentCreated(
  connection: oracledb.Connection,
  actorId: number,
  postId: number,
  commentId: number,
  parentCommentId: number | null | undefined
): Promise<void> {
  const actorName = await v2UserDisplayName(connection, actorId);
  const postAuthorId = await v2PostAuthorId(connection, postId);
  if (postAuthorId) {
    await v2CreateNotification(connection, {
      userId: postAuthorId,
      actorId,
      type: 'comment',
      title: `${actorName} 评论了你的推文`,
      message: '你的推文收到了一条新评论。',
      resourceType: 'comment',
      resourceId: commentId,
      metadata: {
        post_id: postId,
        event: 'comment_created'
      }
    });
  }

  const parentAuthorId = await v2CommentAuthorId(
    connection,
    parentCommentId
  );
  if (parentAuthorId && parentAuthorId !== postAuthorId) {
    await v2CreateNotification(connection, {
      userId: parentAuthorId,
      actorId,
      type: 'comment',
      title: `${actorName} 回复了你的评论`,
      message: '你的评论收到了一条新回复。',
      resourceType: 'comment',
      resourceId: commentId,
      metadata: {
        post_id: postId,
        parent_comment_id: parentCommentId ?? null,
        event: 'comment_reply'
      }
    });
  }
}

async function v2NotifyPostLiked(
  connection: oracledb.Connection,
  actorId: number,
  postId: number
): Promise<void> {
  const postAuthorId = await v2PostAuthorId(connection, postId);
  if (!postAuthorId) return;

  const actorName = await v2UserDisplayName(connection, actorId);
  await v2CreateNotification(connection, {
    userId: postAuthorId,
    actorId,
    type: 'like',
    title: `${actorName} 赞了你的推文`,
    message: '你的推文收到了一次点赞。',
    resourceType: 'post',
    resourceId: postId,
    metadata: {
      event: 'post_like'
    }
  });
}

async function v2NotifyCommentLiked(
  connection: oracledb.Connection,
  actorId: number,
  commentId: number
): Promise<void> {
  const commentAuthorId = await v2CommentAuthorId(
    connection,
    commentId
  );
  if (!commentAuthorId) return;

  const actorName = await v2UserDisplayName(connection, actorId);
  await v2CreateNotification(connection, {
    userId: commentAuthorId,
    actorId,
    type: 'like',
    title: `${actorName} 赞了你的评论`,
    message: '你的评论收到了一次点赞。',
    resourceType: 'comment',
    resourceId: commentId,
    metadata: {
      event: 'comment_like'
    }
  });
}

export async function v2GetPost(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2Post>> {
  const auth = v2Auth(event);
  const post = await v2RequirePostById(
    connection,
    auth.userId,
    postId
  );
  await v2Execute(
    connection,
    `
    UPDATE n_post_stats
    SET views_count = views_count + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  return v2Ok(post);
}

export async function v2DeletePost(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT author_id, is_deleted
    FROM n_posts
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  if (!row || v2Boolean(row.IS_DELETED))
    v2NotFound('帖子不存在');
  if (v2Number(row.AUTHOR_ID) !== auth.userId) {
    v2Unprocessable('只能删除自己的帖子');
  }
  await v2Execute(
    connection,
    `
    UPDATE n_posts
    SET is_deleted = 1
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  return v2Null('post deleted');
}

export async function v2CreateRetweet(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2Post>> {
  const body = await v2Body(event);
  return await v2CreatePostFromPayload(event, connection, {
    content: v2String(body.content),
    visibility: v2PostVisibility(
      v2String(body.visibility, 'public')
    ) as V2CreatePostPayload['visibility'],
    repost_of_post_id: postId,
    reply_to_post_id: null,
    quoted_post_id: null
  });
}

export async function v2PostLikesUsers(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2PublicUser[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const total = await v2Count(
    connection,
    `
    SELECT COUNT(*) AS total
    FROM n_post_likes
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
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
        fn_get_user_relationship(:viewer_id, u.user_id) AS relation,
        ROW_NUMBER() OVER (ORDER BY l.created_at DESC) AS rn
      FROM n_post_likes l
      JOIN v_user_profile_public u ON u.user_id = l.user_id
      WHERE l.post_id = :post_id
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      viewer_id: auth.userId,
      post_id: postId,
      start_row: page.start,
      end_row: page.end
    }
  );
  return v2Ok(
    rows.map(v2MapPublicUser),
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2LikePost(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number,
  liked: boolean
): Promise<V2Response<V2LikePostData>> {
  const auth = v2Auth(event);
  let inserted = 0;
  if (liked) {
    inserted = await v2Execute(
      connection,
      `
      INSERT INTO n_post_likes (post_id, user_id)
      SELECT :post_id, :user_id
      FROM dual
      WHERE NOT EXISTS (
        SELECT 1
        FROM n_post_likes
        WHERE post_id = :post_id
          AND user_id = :user_id
      )
      `,
      { post_id: postId, user_id: auth.userId }
    );
  } else {
    await v2Execute(
      connection,
      `
      DELETE FROM n_post_likes
      WHERE post_id = :post_id
        AND user_id = :user_id
      `,
      { post_id: postId, user_id: auth.userId }
    );
  }
  const row = await v2One(
    connection,
    `
    SELECT likes_count
    FROM n_post_stats
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  if (liked && inserted > 0) {
    await v2NotifyPostLiked(connection, auth.userId, postId);
  }
  return v2Ok({
    post_id: postId,
    is_liked: liked,
    likes_count: v2Number(row?.LIKES_COUNT)
  });
}

export async function v2BookmarkPost(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number,
  bookmarked: boolean
): Promise<V2Response<V2BookmarkPostData>> {
  const auth = v2Auth(event);
  if (bookmarked) {
    await v2Execute(
      connection,
      `
      INSERT INTO n_post_bookmarks (post_id, user_id)
      SELECT :post_id, :user_id
      FROM dual
      WHERE NOT EXISTS (
        SELECT 1
        FROM n_post_bookmarks
        WHERE post_id = :post_id
          AND user_id = :user_id
      )
      `,
      { post_id: postId, user_id: auth.userId }
    );
  } else {
    await v2Execute(
      connection,
      `
      DELETE FROM n_post_bookmarks
      WHERE post_id = :post_id
        AND user_id = :user_id
      `,
      { post_id: postId, user_id: auth.userId }
    );
  }
  return v2Ok({
    post_id: postId,
    is_bookmarked: bookmarked
  });
}

export async function v2ListComments(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2Comment[]>> {
  const auth = v2Auth(event);
  const page = v2Page(event);
  const sort = v2QueryString(event, 'sort', 'newest');
  const order =
    sort === 'oldest'
      ? 'ORDER BY c.created_at ASC'
      : sort === 'popular'
        ? 'ORDER BY c.likes_count DESC, c.created_at DESC'
        : 'ORDER BY c.created_at DESC';
  const total = await v2CommentCount(connection, postId);
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        c.comment_id,
        c.post_id,
        c.user_id,
        c.parent_comment_id,
        c.root_comment_id,
        DBMS_LOB.SUBSTR(c.content, 4000, 1) AS content,
        c.created_at,
        c.updated_at,
        c.likes_count,
        c.replies_count,
        CASE WHEN EXISTS (
          SELECT 1
          FROM n_comment_likes cl
          WHERE cl.comment_id = c.comment_id
            AND cl.user_id = :viewer_id
        ) THEN 1 ELSE 0 END AS is_liked,
        ROW_NUMBER() OVER (${order}) AS rn
      FROM v_post_comment_list_item c
      WHERE c.post_id = :post_id
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      viewer_id: auth.userId,
      post_id: postId,
      start_row: page.start,
      end_row: page.end
    }
  );
  const comments = await Promise.all(
    rows.map(row =>
      v2MapComment(connection, auth.userId, row)
    )
  );
  return v2Ok(
    comments,
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2CreateComment(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2Comment>> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const payload: V2CreateCommentPayload = {
    content: v2RequiredString(body, 'content'),
    parent_comment_id: v2RequiredOptionalNumber(
      body.parent_comment_id
    )
  };
  const commentId = await v2NextId(
    connection,
    'seq_comment_id'
  );
  let rootCommentId: number | null = null;
  if (payload.parent_comment_id) {
    const parent = await v2One(
      connection,
      `
      SELECT NVL(root_comment_id, comment_id) AS root_comment_id
      FROM n_comments
      WHERE comment_id = :comment_id
        AND post_id = :post_id
        AND is_deleted = 0
      `,
      {
        comment_id: payload.parent_comment_id,
        post_id: postId
      }
    );
    if (!parent) v2NotFound('父评论不存在');
    rootCommentId = v2Number(parent.ROOT_COMMENT_ID);
  }

  await v2Execute(
    connection,
    `
    INSERT INTO n_comments (
      comment_id,
      post_id,
      user_id,
      parent_comment_id,
      root_comment_id,
      content
    ) VALUES (
      :comment_id,
      :post_id,
      :user_id,
      :parent_comment_id,
      :root_comment_id,
      :content
    )
    `,
    {
      comment_id: commentId,
      post_id: postId,
      user_id: auth.userId,
      parent_comment_id: payload.parent_comment_id ?? null,
      root_comment_id: rootCommentId ?? commentId,
      content: payload.content
    }
  );

  const row = await v2One(
    connection,
    `
    SELECT
      c.comment_id,
      c.post_id,
      c.user_id,
      c.parent_comment_id,
      c.root_comment_id,
      DBMS_LOB.SUBSTR(c.content, 4000, 1) AS content,
      c.created_at,
      c.updated_at,
      c.likes_count,
      c.replies_count,
      0 AS is_liked
    FROM v_post_comment_list_item c
    WHERE c.comment_id = :comment_id
    `,
    { comment_id: commentId }
  );
  if (!row) v2NotFound('评论不存在');
  await v2NotifyCommentCreated(
    connection,
    auth.userId,
    postId,
    commentId,
    payload.parent_comment_id
  );
  return v2Ok(
    await v2MapComment(connection, auth.userId, row),
    'comment created'
  );
}

export async function v2DeleteComment(
  event: H3Event,
  connection: oracledb.Connection,
  commentId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT user_id, is_deleted
    FROM n_comments
    WHERE comment_id = :comment_id
    `,
    { comment_id: commentId }
  );
  if (!row || v2Boolean(row.IS_DELETED))
    v2NotFound('评论不存在');
  if (v2Number(row.USER_ID) !== auth.userId) {
    v2Unprocessable('只能删除自己的评论');
  }
  await v2Execute(
    connection,
    `
    UPDATE n_comments
    SET is_deleted = 1
    WHERE comment_id = :comment_id
    `,
    { comment_id: commentId }
  );
  return v2Null('comment deleted');
}

export async function v2LikeComment(
  event: H3Event,
  connection: oracledb.Connection,
  commentId: number,
  liked: boolean
): Promise<V2Response<V2LikeCommentData>> {
  const auth = v2Auth(event);
  let inserted = 0;
  if (liked) {
    inserted = await v2Execute(
      connection,
      `
      INSERT INTO n_comment_likes (comment_id, user_id)
      SELECT :comment_id, :user_id
      FROM dual
      WHERE NOT EXISTS (
        SELECT 1
        FROM n_comment_likes
        WHERE comment_id = :comment_id
          AND user_id = :user_id
      )
      `,
      { comment_id: commentId, user_id: auth.userId }
    );
  } else {
    await v2Execute(
      connection,
      `
      DELETE FROM n_comment_likes
      WHERE comment_id = :comment_id
        AND user_id = :user_id
      `,
      { comment_id: commentId, user_id: auth.userId }
    );
  }
  const row = await v2One(
    connection,
    `
    SELECT likes_count
    FROM n_comment_stats
    WHERE comment_id = :comment_id
    `,
    { comment_id: commentId }
  );
  if (liked && inserted > 0) {
    await v2NotifyCommentLiked(
      connection,
      auth.userId,
      commentId
    );
  }
  return v2Ok({
    comment_id: commentId,
    is_liked: liked,
    likes_count: v2Number(row?.LIKES_COUNT)
  });
}

export async function v2PostAnalytics(
  event: H3Event,
  connection: oracledb.Connection,
  postId: number
): Promise<V2Response<V2PostAnalytics>> {
  const auth = v2Auth(event);
  const postRow = await v2One(
    connection,
    `
    SELECT author_id, is_deleted
    FROM n_posts
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  if (!postRow || v2Boolean(postRow.IS_DELETED)) {
    v2NotFound('帖子不存在');
  }
  if (v2Number(postRow.AUTHOR_ID) !== auth.userId) {
    v2Unprocessable('只能查看自己帖子的统计');
  }
  const row = await v2One(
    connection,
    `
    SELECT *
    FROM v_post_analytics
    WHERE post_id = :post_id
    `,
    { post_id: postId }
  );
  if (!row) v2NotFound('帖子不存在');
  const views = v2Number(row.VIEWS_COUNT);
  const likes = v2Number(row.LIKES_COUNT);
  return v2Ok({
    post_id: postId,
    views_count: views,
    likes_count: likes,
    comments_count: v2Number(row.COMMENTS_COUNT),
    replies_count: v2Number(row.REPLIES_COUNT),
    retweets_count: v2Number(row.RETWEETS_COUNT),
    engagement_score: v2Number(row.ENGAGEMENT_SCORE),
    like_rate:
      views > 0 ? Number((likes / views).toFixed(4)) : 0
  });
}

export async function v2SearchTags(
  event: H3Event,
  connection: oracledb.Connection,
  trendingOnly = false
): Promise<V2Response<V2TagItem[]>> {
  v2Auth(event);
  const page = v2Page(event);
  const q = v2QueryString(event, 'q').trim().toLowerCase();
  const where = trendingOnly
    ? 'WHERE is_trending = 1'
    : 'WHERE (:q IS NULL OR name_lower LIKE :q)';
  const binds: Record<string, string | null> = trendingOnly
    ? {}
    : { q: q ? `%${q}%` : null };
  const total = await v2Count(
    connection,
    `SELECT COUNT(*) AS total FROM n_tags ${where}`,
    binds
  );
  const rows = await v2Rows(
    connection,
    `
    SELECT *
    FROM (
      SELECT
        tag_id,
        name,
        usage_count,
        trending_score,
        is_trending,
        updated_at,
        ROW_NUMBER() OVER (
          ORDER BY trending_score DESC, usage_count DESC, updated_at DESC
        ) AS rn
      FROM n_tags
      ${where}
    )
    WHERE rn BETWEEN :start_row AND :end_row
    `,
    {
      ...binds,
      start_row: page.start,
      end_row: page.end
    }
  );
  return v2Ok(
    rows.map(row => ({
      tag_id: v2Number(row.TAG_ID),
      name: v2String(row.NAME),
      usage_count: v2Number(row.USAGE_COUNT),
      trending_score: v2Number(row.TRENDING_SCORE),
      is_trending: v2Number(row.IS_TRENDING),
      updated_at: v2DateString(row.UPDATED_AT) || ''
    })),
    'success',
    v2PageMeta(page.page, page.page_size, total)
  );
}

export async function v2TagAnalytics(
  event: H3Event,
  connection: oracledb.Connection,
  tagName: string
): Promise<V2Response<V2TagAnalytics>> {
  v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT *
    FROM v_tag_analytics
    WHERE name_lower = LOWER(:name)
    `,
    { name: tagName }
  );
  if (!row) v2NotFound('话题不存在');
  return v2Ok({
    name: v2String(row.NAME),
    total_posts: v2Number(row.TOTAL_POSTS),
    total_authors: v2Number(row.TOTAL_AUTHORS),
    total_views: v2Number(row.TOTAL_VIEWS),
    total_likes: v2Number(row.TOTAL_LIKES),
    engagement_score: v2Number(row.AVG_ENGAGEMENT_SCORE)
  });
}

export async function v2RecommendationFeedback(
  event: H3Event
): Promise<V2Response<V2RecommendationFeedbackData>> {
  v2Auth(event);
  const body = await v2Body(event);
  v2RequiredString(body, 'resource_type');
  v2RequiredNumber(body.resource_id, 'resource_id');
  v2RequiredString(body, 'action');
  return v2Ok({ accepted: true });
}

export function v2NullablePostIdFromPath(
  value: string
): number {
  return v2RequiredNumber(value, 'post_id');
}
