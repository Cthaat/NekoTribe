import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import { confirmsCreatedPoll } from './post-polls';
import { isPrivateMediaContent, usesMediaContentRoute } from '../../utils/private-media';
import type {
  V2BookmarkPostData,
  V2Comment,
  V2CreateCommentPayload,
  V2CreatePostPayload,
  V2ApiResponse,
  V2LikeCommentData,
  V2LikePostData,
  V2MediaAsset,
  V2ListMyBookmarkedPostsRequest,
  V2ListMyLikedPostsRequest,
  V2ListMyPostsRequest,
  V2ListPostsRequest,
  V2ListTrendingPostsRequest,
  V2ListUserPostsRequest,
  V2PagedResult,
  V2PageQuery,
  V2Post,
  V2PostAnalytics,
  V2PublicUser,
  V2RetweetPayload,
  V2TagAnalytics,
  V2TagItem,
  V2UpdatePostPayload
} from '@/types/v2';

export async function v2ListPostLikers(postId: number, page: number, signal: AbortSignal) {
  return toV2PagedResult(await v2Request<V2PublicUser[], undefined, V2PageQuery>(
    `/api/v2/posts/${postId}/likes`, { method: 'GET', query: { page, page_size: 20 }, signal }
  ));
}

type PostListQuery =
  | V2ListPostsRequest
  | V2ListTrendingPostsRequest
  | V2ListUserPostsRequest
  | V2ListMyPostsRequest
  | V2ListMyBookmarkedPostsRequest
  | V2ListMyLikedPostsRequest;

export function v2GetTagAnalytics(name: string): Promise<V2TagAnalytics> {
  return v2RequestData<V2TagAnalytics>(`/api/v2/tags/${encodeURIComponent(name)}/analytics`);
}

export function v2SearchTags(q: string, signal: AbortSignal): Promise<V2TagItem[]> {
  return v2RequestData<V2TagItem[], undefined, V2PageQuery & { q: string }>(
    '/api/v2/tags', { query: { q, page_size: 6 }, signal }
  );
}

export async function v2ListTagPosts(name: string, query: V2PageQuery) {
  return toV2PagedResult(await v2Request<V2Post[], undefined, V2PageQuery>(
    `/api/v2/tags/${encodeURIComponent(name)}/posts`, { query }
  ));
}

function logPostListResponse(
  source: string,
  query: PostListQuery,
  response: V2ApiResponse<V2Post[]>
): void {
  console.info(`[v2-api:posts] ${source}`, {
    query,
    code: response.code,
    message: response.message,
    itemCount: response.data.length,
    meta: response.meta,
    firstIds: response.data
      .slice(0, 5)
      .map(post => post.post_id)
  });
}

function normalizePostQuery(
  query: V2ListPostsRequest
): V2ListPostsRequest {
  return {
    page: query.page,
    page_size: query.page_size,
    sort: query.sort,
    timeline: query.timeline,
    q: query.q
  };
}

export async function v2ListPosts(
  query: V2ListPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    ReturnType<typeof normalizePostQuery>
  >('/api/v2/posts', {
    method: 'GET',
    query: normalizePostQuery(query)
  });
  logPostListResponse('list', normalizePostQuery(query), response);
  return toV2PagedResult(response);
}

export async function v2ListTrendingPosts(
  query: V2ListTrendingPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    V2ListTrendingPostsRequest
  >('/api/v2/posts/trending', {
    method: 'GET',
    query
  });
  logPostListResponse('trending', query, response);
  return toV2PagedResult(response);
}

export async function v2ListUserPosts(
  userId: number,
  query: V2ListUserPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    V2ListUserPostsRequest
  >(`/api/v2/users/${userId}/posts`, {
    method: 'GET',
    query
  });
  logPostListResponse('user-posts', query, response);
  return toV2PagedResult(response);
}

export async function v2ListMyPosts(
  query: V2ListMyPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    V2ListMyPostsRequest
  >('/api/v2/users/me/posts', {
    method: 'GET',
    query
  });
  logPostListResponse('my-posts', query, response);
  return toV2PagedResult(response);
}

export async function v2ListMyBookmarkedPosts(
  query: V2ListMyBookmarkedPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    V2ListMyBookmarkedPostsRequest
  >('/api/v2/users/me/bookmarks', {
    method: 'GET',
    query
  });
  logPostListResponse('my-bookmarks', query, response);
  return toV2PagedResult(response);
}

export async function v2ListMyLikedPosts(
  query: V2ListMyLikedPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    V2ListMyLikedPostsRequest
  >('/api/v2/users/me/likes', {
    method: 'GET',
    query
  });
  logPostListResponse('my-likes', query, response);
  return toV2PagedResult(response);
}

export async function v2ListPostReplies(
  postId: number,
  query: V2ListPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  return await listPostReferences(postId, 'replies', query);
}

export async function v2ListPostRetweets(
  postId: number,
  query: V2ListPostsRequest = {}
): Promise<V2PagedResult<V2Post>> {
  return await listPostReferences(postId, 'retweets', query);
}

async function listPostReferences(
  postId: number,
  kind: 'replies' | 'retweets',
  query: V2ListPostsRequest
): Promise<V2PagedResult<V2Post>> {
  const normalizedQuery = normalizePostQuery(query);
  const response = await v2Request<
    V2Post[],
    undefined,
    ReturnType<typeof normalizePostQuery>
  >(`/api/v2/posts/${postId}/${kind}`, {
    method: 'GET',
    query: normalizedQuery
  });
  logPostListResponse(
    `post-${kind}`,
    normalizedQuery,
    response
  );
  return toV2PagedResult(response);
}

export async function v2GetPost(
  postId: number,
  signal?: AbortSignal
): Promise<V2Post> {
  const post = await v2RequestData<V2Post>(`/api/v2/posts/${postId}`, {
    method: 'GET', signal
  });
  if (!post || post.post_id !== postId) throw new Error('Invalid post detail response');
  return post;
}

export async function v2GetPostAnalytics(
  postId: number
): Promise<V2PostAnalytics> {
  return await v2RequestData<V2PostAnalytics>(
    `/api/v2/posts/${postId}/analytics`,
    {
      method: 'GET'
    }
  );
}

export async function v2DeletePost(
  postId: number
): Promise<void> {
  const response = await v2Request<null>(`/api/v2/posts/${postId}`, {
    method: 'DELETE'
  });
  if (!response || response.code !== 200 || response.message !== 'post deleted' ||
      response.data !== null || response.meta !== null) {
    throw new Error('Invalid post delete response');
  }
}

export class UnconfirmedPostError extends Error {
  override name = 'UnconfirmedPostError';

  constructor() {
    super('Post receipt did not confirm the created post');
  }
}

export async function v2CreatePost(
  payload: V2CreatePostPayload
): Promise<V2Post> {
  const result = await v2RequestData<V2Post, V2CreatePostPayload>(
    '/api/v2/posts',
    {
      method: 'POST',
      body: payload
    }
  );
  const reply = payload.reply_to_post_id ?? null;
  const repost = payload.repost_of_post_id ?? null;
  const quote = payload.quoted_post_id ?? null;
  if (!result || !Number.isSafeInteger(result.post_id) || result.post_id < 1 ||
      [reply, repost, quote].includes(result.post_id) ||
      (result.reply_to_post_id ?? null) !== reply ||
      (result.repost_of_post_id ?? null) !== repost ||
      (result.quoted_post_id ?? null) !== quote || payload.poll && !confirmsCreatedPoll(result.poll,payload.poll) ||
      payload.markdown !== undefined && result.markdown !== payload.markdown) {
    throw new UnconfirmedPostError();
  }
  return result;
}

export class UnconfirmedPostUpdateError extends Error {
  override name = 'UnconfirmedPostUpdateError';

  constructor() {
    super('Post update receipt did not confirm the saved post');
  }
}

export async function v2UpdatePost(
  postId: number,
  payload: V2UpdatePostPayload,
  signal?: AbortSignal
): Promise<V2Post> {
  const response = await v2Request<V2Post, V2UpdatePostPayload>(
    `/api/v2/posts/${postId}`,
    {
      method: 'PATCH',
      body: payload,
      signal
    }
  );
  const post = response?.data;
  if (response?.code !== 200 || response.message !== 'post updated' ||
      response.meta !== null || post?.post_id !== postId ||
      !Number.isSafeInteger(post.author?.user_id) || post.author.user_id < 1 ||
      post.viewer_state?.can_delete !== true ||
      payload.markdown !== undefined && post.markdown !== (payload.markdown ?? undefined)) {
    throw new UnconfirmedPostUpdateError();
  }
  return post;
}

export class UnconfirmedRetweetError extends Error {
  override name = 'UnconfirmedRetweetError';

  constructor() {
    super('Retweet receipt did not confirm the created post');
  }
}

export async function v2CreateRetweet(
  postId: number,
  payload: V2RetweetPayload
): Promise<V2Post> {
  const result = await v2RequestData<V2Post, V2RetweetPayload>(
    `/api/v2/posts/${postId}/retweets`,
    {
      method: 'POST',
      body: payload
    }
  );
  if (!result || result.repost_of_post_id !== postId ||
      !Number.isSafeInteger(result.post_id) || result.post_id < 1 || result.post_id === postId) {
    throw new UnconfirmedRetweetError();
  }
  return result;
}

export type RecommendationAction = 'not_interested' | 'show_less';

export async function v2SendRecommendationFeedback(postId: number, action: RecommendationAction): Promise<boolean> {
  const body = { resource_type: 'post', resource_id: postId, action };
  const result = await v2RequestData<{ accepted: boolean }, typeof body>('/api/v2/recommendations/feedback', {
    method: 'POST', body
  });
  return result.accepted === true;
}

async function setPostLike(postId: number, method: 'POST' | 'DELETE'): Promise<V2LikePostData> {
  const result = await v2RequestData<V2LikePostData>(
    `/api/v2/posts/${postId}/likes`,
    { method }
  );
  if (!result || result.post_id !== postId || typeof result.is_liked !== 'boolean' ||
      !Number.isSafeInteger(result.likes_count) || result.likes_count < 0) {
    throw new Error('Invalid post like response');
  }
  return result;
}

export const v2LikePost = (postId: number) => setPostLike(postId, 'POST');
export const v2UnlikePost = (postId: number) => setPostLike(postId, 'DELETE');

async function setPostBookmark(postId: number, method: 'POST' | 'DELETE'): Promise<V2BookmarkPostData> {
  const result = await v2RequestData<V2BookmarkPostData>(
    `/api/v2/posts/${postId}/bookmarks`,
    { method }
  );
  if (!result || result.post_id !== postId || typeof result.is_bookmarked !== 'boolean') {
    throw new Error('Invalid post bookmark response');
  }
  return result;
}

export const v2BookmarkPost = (postId: number) => setPostBookmark(postId, 'POST');
export const v2UnbookmarkPost = (postId: number) => setPostBookmark(postId, 'DELETE');

export async function v2ListComments(
  postId: number,
  query: {
    page?: number;
    page_size?: number;
    comment_id?: number;
    sort?: 'newest' | 'oldest' | 'popular';
  } = {}
): Promise<V2PagedResult<V2Comment>> {
  const response = await v2Request<
    V2Comment[],
    undefined,
    typeof query
  >(`/api/v2/posts/${postId}/comments`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2CreateComment(
  postId: number,
  payload: V2CreateCommentPayload
): Promise<V2Comment> {
  return await v2RequestData<
    V2Comment,
    V2CreateCommentPayload
  >(`/api/v2/posts/${postId}/comments`, {
    method: 'POST',
    body: payload
  });
}

export async function v2DeleteComment(
  commentId: number
): Promise<void> {
  await v2RequestData<null>(`/api/v2/comments/${commentId}`, {
    method: 'DELETE'
  });
}

export async function v2LikeComment(
  commentId: number
): Promise<V2LikeCommentData> {
  return await v2RequestData<V2LikeCommentData>(
    `/api/v2/comments/${commentId}/likes`,
    {
      method: 'POST'
    }
  );
}

export async function v2UnlikeComment(
  commentId: number
): Promise<V2LikeCommentData> {
  return await v2RequestData<V2LikeCommentData>(
    `/api/v2/comments/${commentId}/likes`,
    {
      method: 'DELETE'
    }
  );
}

export async function v2UploadMedia(
  body: FormData | {
    media_type: string;
    file_name: string;
    storage_key?: string;
    public_url: string;
    file_size: number;
    mime_type?: string;
    width?: number | null;
    height?: number | null;
    duration?: number | null;
    thumbnail_url?: string | null;
    alt_text?: string | null;
    description?: string | null;
    status?: string;
  },
  signal?: AbortSignal
): Promise<V2MediaAsset> {
  const scope = body instanceof FormData ? body.get('access_scope') : null;
  const privateUpload = scope !== null && scope !== 'public';
  const response = await v2Request<V2MediaAsset, typeof body>(
    privateUpload ? '/api/v2/media/private' : '/api/v2/media',
    {
      method: 'POST',
      body,
      signal,
      ...(privateUpload ? { redirect: 'error' } : {})
    }
  );
  const asset = response?.data;
  if (response?.code !== 200 || response.message !== 'media uploaded' ||
      response.meta !== null || !asset || !Number.isSafeInteger(asset.media_id) ||
      asset.media_id <= 0 || asset.status !== 'ready' ||
      typeof asset.public_url !== 'string' || !asset.public_url.trim() ||
      (privateUpload
        ? !isPrivateMediaContent(asset.media_id, asset.public_url) || asset.thumbnail_url !== null
        : usesMediaContentRoute(asset.public_url))) {
    throw new Error('Invalid uploaded attachment');
  }
  return asset;
}

export async function v2DeleteMedia(mediaId: number): Promise<void> {
  await v2RequestData<null>(`/api/v2/media/${mediaId}`, { method: 'DELETE' });
}

