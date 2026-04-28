import type {
  V2ApiMeta,
  V2Comment,
  V2CreateCommentPayload,
  V2CreatePostPayload,
  V2MediaAsset,
  V2PagedResult,
  V2Post,
  V2PublicUser,
  V2RetweetPayload
} from '@/types/v2';
import type {
  CommentLikeVM,
  CommentPageVM,
  CommentVM,
  CreateCommentFormVM,
  CreatePostFormVM,
  CreateRetweetFormVM,
  PageViewModel,
  PostAuthorVM,
  PostBookmarkVM,
  PostFeedPageRequest,
  PostLikeVM,
  PostMediaType,
  PostMediaVM,
  PostPageVM,
  PostTimelineType,
  PostVM,
  PreviewPostVM
} from '@/types/posts';
import {
  v2BookmarkPost as apiBookmarkPost,
  v2CreateComment as apiCreateComment,
  v2CreatePost as apiCreatePost,
  v2CreateRetweet as apiCreateRetweet,
  v2DeleteComment,
  v2DeletePost,
  v2GetPost as apiGetPost,
  v2LikeComment as apiLikeComment,
  v2LikePost as apiLikePost,
  v2ListComments as apiListComments,
  v2ListMyBookmarkedPosts as apiListMyBookmarkedPosts,
  v2ListMyPosts as apiListMyPosts,
  v2ListPosts as apiListPosts,
  v2ListTrendingPosts as apiListTrendingPosts,
  v2ListUserPosts as apiListUserPosts,
  v2UnlikeComment as apiUnlikeComment,
  v2UnlikePost as apiUnlikePost,
  v2UnbookmarkPost as apiUnbookmarkPost,
  v2UploadMedia
} from '@/api/v2/posts';
import {
  normalizeAssetUrl,
  normalizeAvatarUrl
} from '@/utils/assets';

export {
  v2DeleteComment,
  v2DeletePost,
  v2UploadMedia
} from '@/api/v2/posts';

function logPostsService(
  message: string,
  payload: Record<string, unknown>
): void {
  console.info(`[posts-service] ${message}`, payload);
}

function mediaTypeOf(media: V2MediaAsset): PostMediaType {
  return media.media_type === 'video' ||
    media.mime_type.startsWith('video/')
    ? 'video'
    : 'image';
}

function mapPageMeta<TDto, TViewModel>(
  result: V2PagedResult<TDto>,
  items: TViewModel[]
): PageViewModel<TViewModel> {
  const meta: V2ApiMeta | null = result.meta;
  return {
    items,
    total: meta?.total ?? items.length,
    page: meta?.page ?? 1,
    pageSize: meta?.page_size ?? items.length,
    hasNext: meta?.has_next ?? false
  };
}

export function mapPublicUserToPostAuthor(
  user: V2PublicUser
): PostAuthorVM {
  return {
    id: user.user_id,
    username: user.username,
    name: user.display_name,
    avatarUrl: normalizeAvatarUrl(user.avatar_url),
    bio: user.bio,
    location: user.location,
    website: user.website,
    verified: user.is_verified === 1,
    followersCount: user.followers_count,
    followingCount: user.following_count,
    postsCount: user.posts_count,
    likesCount: user.likes_count,
    relation: user.relationship.relation
  };
}

export function mapMediaToPostMedia(
  media: V2MediaAsset
): PostMediaVM {
  return {
    id: media.media_id,
    type: mediaTypeOf(media),
    originalUrl: normalizeAssetUrl(media.public_url),
    thumbnailUrl: normalizeAssetUrl(
      media.thumbnail_url || media.public_url
    ),
    altText: media.alt_text
  };
}

export function mapPost(dto: V2Post): PostVM {
  return {
    id: dto.post_id,
    author: mapPublicUserToPostAuthor(dto.author),
    content: dto.content,
    postType: dto.post_type,
    visibility: dto.visibility,
    language: dto.language,
    location: dto.location,
    replyToPostId: dto.reply_to_post_id,
    repostOfPostId: dto.repost_of_post_id,
    quotedPostId: dto.quoted_post_id,
    media: dto.media.map(mapMediaToPostMedia),
    tags: dto.tags,
    mentions: dto.mentions.map(mapPublicUserToPostAuthor),
    counts: {
      likes: dto.stats.likes_count,
      comments: dto.stats.comments_count,
      replies: dto.stats.replies_count,
      retweets: dto.stats.retweets_count,
      views: dto.stats.views_count,
      engagementScore: dto.stats.engagement_score
    },
    viewer: {
      hasLiked: dto.viewer_state.is_liked,
      hasBookmarked: dto.viewer_state.is_bookmarked,
      canDelete: dto.viewer_state.can_delete
    },
    createdAt: dto.created_at,
    updatedAt: dto.updated_at
  };
}

export function mapPostToPreview(dto: V2Post): PreviewPostVM {
  return {
    id: dto.post_id,
    author: {
      name: dto.author.display_name,
      username: dto.author.username,
      avatarUrl: normalizeAvatarUrl(dto.author.avatar_url)
    },
    content: dto.content
  };
}

export function mapComment(dto: V2Comment): CommentVM {
  return {
    id: dto.comment_id,
    postId: dto.post_id,
    author: mapPublicUserToPostAuthor(dto.author),
    parentCommentId: dto.parent_comment_id,
    rootCommentId: dto.root_comment_id,
    content: dto.content,
    counts: {
      likes: dto.stats.likes_count,
      replies: dto.stats.replies_count
    },
    viewer: {
      hasLiked: dto.viewer_state.is_liked,
      canDelete: dto.viewer_state.can_delete
    },
    createdAt: dto.created_at,
    updatedAt: dto.updated_at
  };
}

function mapPostPage(
  result: V2PagedResult<V2Post>
): PostPageVM {
  const posts = result.items.map(mapPost);
  logPostsService('mapPostPage', {
    rawCount: result.items.length,
    mappedCount: posts.length,
    meta: result.meta,
    rawFirstIds: result.items
      .slice(0, 5)
      .map(post => post.post_id),
    mappedFirstIds: posts.slice(0, 5).map(post => post.id)
  });
  return mapPageMeta(result, posts);
}

function mapCommentPage(
  result: V2PagedResult<V2Comment>
): CommentPageVM {
  const comments = result.items.map(mapComment);
  return mapPageMeta(result, comments);
}

function mapCreatePostForm(
  form: CreatePostFormVM
): V2CreatePostPayload {
  return {
    content: form.content,
    visibility: form.visibility,
    media_ids: form.mediaIds,
    tag_names: form.tagNames,
    mention_user_ids: form.mentionUserIds,
    reply_to_post_id: form.replyToPostId,
    repost_of_post_id: form.repostOfPostId,
    quoted_post_id: form.quotedPostId,
    location: form.location
  };
}

function mapCreateCommentForm(
  form: CreateCommentFormVM
): V2CreateCommentPayload {
  return {
    content: form.content,
    parent_comment_id: form.parentCommentId
  };
}

function mapCreateRetweetForm(
  form: CreateRetweetFormVM
): V2RetweetPayload {
  return {
    content: form.content,
    visibility: form.visibility
  };
}

export function normalizePostTimelineType(
  value: string
): PostTimelineType {
  if (
    value === 'home' ||
    value === 'my_tweets' ||
    value === 'mention' ||
    value === 'bookmark' ||
    value === 'trending' ||
    value === 'user'
  ) {
    return value;
  }

  return 'home';
}

export async function v2ListPosts(query: {
  page?: number;
  pageSize?: number;
  sort?: 'newest' | 'oldest' | 'popular';
  timeline?: 'home' | 'mentions';
  q?: string;
} = {}): Promise<PostPageVM> {
  return mapPostPage(await apiListPosts({
    page: query.page,
    page_size: query.pageSize,
    sort: query.sort,
    timeline: query.timeline,
    q: query.q
  }));
}

export async function v2ListPostPreviews(query: {
  page?: number;
  pageSize?: number;
  sort?: 'newest' | 'oldest' | 'popular';
  timeline?: 'home' | 'mentions';
  q?: string;
} = {}): Promise<PageViewModel<PreviewPostVM>> {
  const result = await apiListPosts({
    page: query.page,
    page_size: query.pageSize,
    sort: query.sort,
    timeline: query.timeline,
    q: query.q
  });
  return mapPageMeta(result, result.items.map(mapPostToPreview));
}

export async function v2ListTrendingPosts(query: {
  page?: number;
  pageSize?: number;
} = {}): Promise<PostPageVM> {
  return mapPostPage(await apiListTrendingPosts({
    page: query.page,
    page_size: query.pageSize
  }));
}

export async function v2ListUserPosts(
  userId: number,
  query: {
    page?: number;
    pageSize?: number;
    sort?: 'newest' | 'oldest' | 'popular';
  } = {}
): Promise<PostPageVM> {
  return mapPostPage(await apiListUserPosts(userId, {
    page: query.page,
    page_size: query.pageSize,
    sort: query.sort
  }));
}

export async function v2ListMyPosts(query: {
  page?: number;
  pageSize?: number;
} = {}): Promise<PostPageVM> {
  return mapPostPage(await apiListMyPosts({
    page: query.page,
    page_size: query.pageSize
  }));
}

export async function v2ListMyBookmarkedPosts(query: {
  page?: number;
  pageSize?: number;
  sort?: 'newest' | 'oldest' | 'popular';
} = {}): Promise<PostPageVM> {
  return mapPostPage(await apiListMyBookmarkedPosts({
    page: query.page,
    page_size: query.pageSize,
    sort: query.sort
  }));
}

export async function v2ListTimelinePosts(
  request: PostFeedPageRequest
): Promise<PostPageVM> {
  const query = {
    page: request.page,
    pageSize: request.pageSize
  };

  if (request.type === 'trending') {
    logPostsService('timeline:branch', {
      type: request.type,
      userId: request.userId,
      page: request.page,
      pageSize: request.pageSize,
      branch: 'trending'
    });
    return await v2ListTrendingPosts(query);
  }

  if (request.type === 'my_tweets') {
    logPostsService('timeline:branch', {
      type: request.type,
      userId: request.userId,
      page: request.page,
      pageSize: request.pageSize,
      branch: 'my-posts'
    });
    return await v2ListMyPosts(query);
  }

  if (request.type === 'mention') {
    logPostsService('timeline:branch', {
      type: request.type,
      userId: request.userId,
      page: request.page,
      pageSize: request.pageSize,
      branch: 'mentions'
    });
    return await v2ListPosts({
      ...query,
      sort: request.sort ?? 'newest',
      timeline: 'mentions'
    });
  }

  if (request.type === 'bookmark') {
    logPostsService('timeline:branch', {
      type: request.type,
      userId: request.userId,
      page: request.page,
      pageSize: request.pageSize,
      branch: 'bookmarks'
    });
    return await v2ListMyBookmarkedPosts({
      ...query,
      sort: request.sort ?? 'newest'
    });
  }

  if (request.type === 'user' && request.userId) {
    logPostsService('timeline:branch', {
      type: request.type,
      userId: request.userId,
      page: request.page,
      pageSize: request.pageSize,
      branch: 'user-posts'
    });
    return await v2ListUserPosts(request.userId, {
      ...query,
      sort: request.sort ?? 'newest'
    });
  }

  logPostsService('timeline:branch', {
    type: request.type,
    userId: request.userId,
    page: request.page,
    pageSize: request.pageSize,
    branch: 'home'
  });
  return await v2ListPosts({
    ...query,
    sort: request.sort ?? 'newest',
    timeline: 'home'
  });
}

export async function v2GetPost(
  postId: number
): Promise<PostVM> {
  return mapPost(await apiGetPost(postId));
}

export async function v2CreatePost(
  form: CreatePostFormVM
): Promise<PostVM> {
  return mapPost(await apiCreatePost(mapCreatePostForm(form)));
}

export async function v2CreateRetweet(
  postId: number,
  form: CreateRetweetFormVM
): Promise<PostVM> {
  return mapPost(await apiCreateRetweet(postId, mapCreateRetweetForm(form)));
}

export async function v2LikePost(
  postId: number
): Promise<PostLikeVM> {
  const result = await apiLikePost(postId);
  return {
    postId: result.post_id,
    isLiked: result.is_liked,
    likesCount: result.likes_count
  };
}

export async function v2UnlikePost(
  postId: number
): Promise<PostLikeVM> {
  const result = await apiUnlikePost(postId);
  return {
    postId: result.post_id,
    isLiked: result.is_liked,
    likesCount: result.likes_count
  };
}

export async function v2BookmarkPost(
  postId: number
): Promise<PostBookmarkVM> {
  const result = await apiBookmarkPost(postId);
  return {
    postId: result.post_id,
    isBookmarked: result.is_bookmarked
  };
}

export async function v2UnbookmarkPost(
  postId: number
): Promise<PostBookmarkVM> {
  const result = await apiUnbookmarkPost(postId);
  return {
    postId: result.post_id,
    isBookmarked: result.is_bookmarked
  };
}

export async function v2ListComments(
  postId: number,
  query: {
    page?: number;
    pageSize?: number;
    sort?: 'newest' | 'oldest' | 'popular';
  } = {}
): Promise<CommentPageVM> {
  return mapCommentPage(await apiListComments(postId, {
    page: query.page,
    page_size: query.pageSize,
    sort: query.sort
  }));
}

export async function v2CreateComment(
  postId: number,
  form: CreateCommentFormVM
): Promise<CommentVM> {
  return mapComment(await apiCreateComment(postId, mapCreateCommentForm(form)));
}

export async function v2LikeComment(
  commentId: number
): Promise<CommentLikeVM> {
  const result = await apiLikeComment(commentId);
  return {
    commentId: result.comment_id,
    isLiked: result.is_liked,
    likesCount: result.likes_count
  };
}

export async function v2UnlikeComment(
  commentId: number
): Promise<CommentLikeVM> {
  const result = await apiUnlikeComment(commentId);
  return {
    commentId: result.comment_id,
    isLiked: result.is_liked,
    likesCount: result.likes_count
  };
}
