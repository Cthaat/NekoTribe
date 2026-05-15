import type {
  V2PostSort,
  V2PostVisibility
} from '@/types/v2';

export type PostTimelineType =
  | 'home'
  | 'my_tweets'
  | 'mention'
  | 'bookmark'
  | 'trending'
  | 'user';

export interface PostFeedPageRequest {
  type: PostTimelineType;
  page?: number;
  pageSize?: number;
  userId?: number;
  sort?: V2PostSort;
}

export interface PageViewModel<T> {
  items: T[];
  total: number;
  page: number;
  pageSize: number;
  hasNext: boolean;
}

export interface PostAuthorVM {
  id: number;
  username: string;
  name: string;
  avatarUrl: string;
  bio: string;
  location: string;
  website: string;
  verified: boolean;
  followersCount: number;
  followingCount: number;
  postsCount: number;
  likesCount: number;
  relation: string;
}

export type PostMediaType = 'image' | 'video';

export interface PostMediaVM {
  id: number;
  type: PostMediaType;
  originalUrl: string;
  thumbnailUrl: string;
  altText: string | null;
}

export interface PostCountsVM {
  likes: number;
  comments: number;
  replies: number;
  retweets: number;
  views: number;
  engagementScore: number;
}

export interface PostViewerStateVM {
  hasLiked: boolean;
  hasBookmarked: boolean;
  canDelete: boolean;
}

export interface PostVM {
  id: number;
  author: PostAuthorVM;
  content: string;
  postType: string;
  visibility: string;
  language: string;
  location: string;
  replyToPostId: number | null;
  repostOfPostId: number | null;
  quotedPostId: number | null;
  media: PostMediaVM[];
  tags: string[];
  mentions: PostAuthorVM[];
  counts: PostCountsVM;
  viewer: PostViewerStateVM;
  createdAt: string;
  updatedAt: string;
}

export interface CommentCountsVM {
  likes: number;
  replies: number;
}

export interface CommentViewerStateVM {
  hasLiked: boolean;
  canDelete: boolean;
}

export interface CommentVM {
  id: number;
  postId: number;
  author: PostAuthorVM;
  parentCommentId: number | null;
  rootCommentId: number | null;
  content: string;
  counts: CommentCountsVM;
  viewer: CommentViewerStateVM;
  createdAt: string;
  updatedAt: string;
}

export interface NestedCommentVM extends CommentVM {
  children: NestedCommentVM[];
}

export interface PreviewPostVM {
  id: number;
  author: {
    name: string;
    username: string;
    avatarUrl: string;
  };
  content: string;
}

export interface CreatePostFormVM {
  content?: string;
  visibility?: V2PostVisibility;
  mediaIds?: number[];
  tagNames?: string[];
  mentionUserIds?: number[];
  replyToPostId?: number | null;
  repostOfPostId?: number | null;
  quotedPostId?: number | null;
  location?: string;
}

export interface UpdatePostFormVM {
  content?: string;
  visibility?: V2PostVisibility;
  language?: string;
  location?: string | null;
  mediaIds?: number[];
  tagNames?: string[];
  mentionUserIds?: number[];
}

export interface CreateRetweetFormVM {
  content?: string;
  visibility?: V2PostVisibility;
}

export interface CreateCommentFormVM {
  content: string;
  parentCommentId?: number | null;
}

export type PostPageVM = PageViewModel<PostVM>;
export type CommentPageVM = PageViewModel<CommentVM>;

export interface PostLikeVM {
  postId: number;
  isLiked: boolean;
  likesCount: number;
}

export interface PostBookmarkVM {
  postId: number;
  isBookmarked: boolean;
}

export interface PostAnalyticsVM {
  postId: number;
  views: number;
  likes: number;
  comments: number;
  replies: number;
  retweets: number;
  engagementScore: number;
  likeRate: number;
}

export interface CommentLikeVM {
  commentId: number;
  isLiked: boolean;
  likesCount: number;
}
