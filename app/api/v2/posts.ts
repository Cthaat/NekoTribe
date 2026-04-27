import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import type {
  V2BookmarkPostData,
  V2Comment,
  V2CreateCommentPayload,
  V2CreatePostPayload,
  V2LikeCommentData,
  V2LikePostData,
  V2MediaAsset,
  V2PagedResult,
  V2Post,
  V2RetweetPayload
} from '@/types/v2';

function normalizePostQuery(query: {
  page?: number;
  page_size?: number;
  sort?: string;
  timeline?: string;
  q?: string;
}) {
  return {
    page: query.page,
    page_size: query.page_size,
    sort: query.sort,
    timeline: query.timeline,
    q: query.q
  };
}

export async function v2ListPosts(query: {
  page?: number;
  page_size?: number;
  sort?: 'newest' | 'oldest' | 'popular';
  timeline?: 'home' | 'mentions';
  q?: string;
} = {}): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    ReturnType<typeof normalizePostQuery>
  >('/api/v2/posts', {
    method: 'GET',
    query: normalizePostQuery(query)
  });
  return toV2PagedResult(response);
}

export async function v2ListTrendingPosts(query: {
  page?: number;
  page_size?: number;
} = {}): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    typeof query
  >('/api/v2/posts/trending', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ListUserPosts(
  userId: number,
  query: {
    page?: number;
    page_size?: number;
    sort?: 'newest' | 'oldest' | 'popular';
  } = {}
): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    typeof query
  >(`/api/v2/users/${userId}/posts`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ListMyBookmarkedPosts(query: {
  page?: number;
  page_size?: number;
  sort?: 'newest' | 'oldest' | 'popular';
} = {}): Promise<V2PagedResult<V2Post>> {
  const response = await v2Request<
    V2Post[],
    undefined,
    typeof query
  >('/api/v2/users/me/bookmarks', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2GetPost(
  postId: number
): Promise<V2Post> {
  return await v2RequestData<V2Post>(`/api/v2/posts/${postId}`, {
    method: 'GET'
  });
}

export async function v2DeletePost(
  postId: number
): Promise<void> {
  await v2RequestData<null>(`/api/v2/posts/${postId}`, {
    method: 'DELETE'
  });
}

export async function v2CreatePost(
  payload: V2CreatePostPayload
): Promise<V2Post> {
  return await v2RequestData<V2Post, V2CreatePostPayload>(
    '/api/v2/posts',
    {
      method: 'POST',
      body: payload
    }
  );
}

export async function v2CreateRetweet(
  postId: number,
  payload: V2RetweetPayload
): Promise<V2Post> {
  return await v2RequestData<V2Post, V2RetweetPayload>(
    `/api/v2/posts/${postId}/retweets`,
    {
      method: 'POST',
      body: payload
    }
  );
}

export async function v2LikePost(
  postId: number
): Promise<V2LikePostData> {
  return await v2RequestData<V2LikePostData>(
    `/api/v2/posts/${postId}/likes`,
    {
      method: 'POST'
    }
  );
}

export async function v2UnlikePost(
  postId: number
): Promise<V2LikePostData> {
  return await v2RequestData<V2LikePostData>(
    `/api/v2/posts/${postId}/likes`,
    {
      method: 'DELETE'
    }
  );
}

export async function v2BookmarkPost(
  postId: number
): Promise<V2BookmarkPostData> {
  return await v2RequestData<V2BookmarkPostData>(
    `/api/v2/posts/${postId}/bookmarks`,
    {
      method: 'POST'
    }
  );
}

export async function v2UnbookmarkPost(
  postId: number
): Promise<V2BookmarkPostData> {
  return await v2RequestData<V2BookmarkPostData>(
    `/api/v2/posts/${postId}/bookmarks`,
    {
      method: 'DELETE'
    }
  );
}

export async function v2ListComments(
  postId: number,
  query: {
    page?: number;
    page_size?: number;
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
    status?: string;
  }
): Promise<V2MediaAsset> {
  return await v2RequestData<V2MediaAsset, typeof body>(
    '/api/v2/media',
    {
      method: 'POST',
      body
    }
  );
}

