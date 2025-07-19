// ========================== send-tweets.post ======================================

interface TweetSendPayload {
  content: string; // 推文内容（最多280字符）
  mediaIds?: number[]; // 媒体文件ID数组（可选）
  replyToTweetId?: number; // 回复的推文ID（可选）
  retweetOfTweetId?: number; // 转发的推文ID（可选）
  quoteTweetId?: number; // 引用的推文ID（可选）
  visibility?: 'public' | 'followers' | 'private'; // 可见性（可选）
  hashtags?: string[]; // 话题标签（可选）
  mentions?: string[]; // 提及的用户名（可选）
  scheduledAt?: string; // 定时发布时间（可选，ISO字符串）
  location?: string; // 地理位置（可选）
}

// ========================== list.get ============================================

interface TweetListPayload {
  type:
    | 'home'
    | 'user'
    | 'my_tweets'
    | 'mention'
    | 'trending'
    | 'bookmark'; // 推文类型
  page: number; // 页码
  pageSize: number; // 每页数量
  userId?: string; // 用户ID（仅在type为'user'时需要）
}

type TweetRow = [
  string, // TWEET_ID
  string, // AUTHOR_ID
  string, // USERNAME
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  number, // IS_VERIFIED
  number, // LIKES_COUNT
  number, // RETWEETS_COUNT
  number, // REPLIES_COUNT
  number, // VIEWS_COUNT
  string, // VISIBILITY
  string, // CREATED_AT
  string, // REPLY_TO_TWEET_ID
  string, // RETWEET_OF_TWEET_ID
  string, // QUOTE_TWEET_ID
  number, // ENGAGEMENT_SCORE
  string, // TIMELINE_TYPE
  number, // IS_FROM_FOLLOWING
  number, // RN
  number, // IS_LIKED_BY_USER
  number // IS_BOOKMARKED_BY_USER
];

interface TweetItem {
  tweetId: string; // 推文ID
  authorId: string; // 作者ID
  username: string; // 作者用户名
  displayName: string; // 作者显示名
  avatarUrl: string; // 作者头像
  isVerified: number; // 是否认证
  likesCount: number; // 点赞数
  retweetsCount: number; // 转发数
  repliesCount: number; // 回复数
  viewsCount: number; // 浏览量
  visibility: string; // 可见性
  createdAt: string; // 创建时间
  replyToTweetId: string; // 回复的推文ID
  retweetOfTweetId: string; // 转发的推文ID
  quoteTweetId: string; // 引用的推文ID
  engagementScore: number; // 互动分数
  timelineType: string; // 时间线类型
  isFromFollowing: number; // 是否来自关注
  rn: number; // 行号
  isLikedByUser: number; // 用户是否点赞
  isBookmarkedByUser: number; // 用户是否收藏
}

interface TweetListResponse extends Response {
  success: true;
  message: string;
  data: {
    type:
      | 'home'
      | 'user'
      | 'my_tweets'
      | 'mention'
      | 'trending'; // 推文类型
    page: number; // 当前页码
    pageSize: number; // 每页数量
    tweets: TweetItem[]; // 推文列表
    totalCount?: number; // 总推文数（可选）
  };
  code: 200;
  timestamp: string;
}

// ========================== [tweetId].get ======================================

type TweetGetRow = [
  string, // TWEET_ID
  any, // CONTENT
  string, // AUTHOR_ID
  string, // USERNAME
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  number, // IS_VERIFIED
  string, // REPLY_TO_TWEET_ID
  string, // RETWEET_OF_TWEET_ID
  string, // QUOTE_TWEET_ID
  number, // IS_RETWEET
  number, // IS_QUOTE_TWEET
  number, // LIKES_COUNT
  number, // RETWEETS_COUNT
  number, // REPLIES_COUNT
  number, // VIEWS_COUNT
  string, // VISIBILITY
  string, // LANGUAGE
  string, // CREATED_AT
  number, // ENGAGEMENT_SCORE
  any[], // MEDIA_FILES
  any, // MEDIA_THUMBNAILS
  number, // is_liked_by_user
  number // is_bookmarked_by_user
];

interface TweetGetItem {
  tweetId: string; // 推文ID
  content: string; // 推文内容（CLOB需转字符串）
  authorId: string; // 作者ID
  username: string; // 作者用户名
  displayName: string; // 作者显示名
  avatarUrl: string; // 作者头像
  isVerified: number; // 是否认证
  replyToTweetId: string; // 回复的推文ID
  retweetOfTweetId: string; // 转发的推文ID
  quoteTweetId: string; // 引用的推文ID
  isRetweet: number; // 是否为转发
  isQuoteTweet: number; // 是否为引用
  likesCount: number; // 点赞数
  retweetsCount: number; // 转发数
  repliesCount: number; // 回复数
  viewsCount: number; // 浏览量
  visibility: string; // 可见性
  language: string; // 语言
  createdAt: string; // 创建时间
  engagementScore: number; // 互动分数
  mediaFiles: any[]; // 媒体文件数组
  mediaThumbnails: any; // 媒体缩略图
  isLikedByUser: number; // 用户是否点赞
  isBookmarkedByUser: number; // 用户是否收藏
}

interface TweetGetResponse extends Response {
  success: true;
  message: string;
  data: {
    tweet: TweetGetItem; // 推文
  };
  code: 200;
  timestamp: string;
}

// ========================== [tweetId].replies.get ======================================

interface TweetRepliesPayload {
  page: number; // 页码
  pageSize: number; // 每页数量
}

type TweetGetRepliesRow = [
  string, // TWEET_ID
  any, // CONTENT
  string, // AUTHOR_ID
  string, // USERNAME
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  number, // IS_VERIFIED
  string, // REPLY_TO_TWEET_ID
  string, // RETWEET_OF_TWEET_ID
  string, // QUOTE_TWEET_ID
  number, // IS_RETWEET
  number, // IS_QUOTE_TWEET
  number, // LIKES_COUNT
  number, // RETWEETS_COUNT
  number, // REPLIES_COUNT
  number, // VIEWS_COUNT
  string, // VISIBILITY
  string, // LANGUAGE
  string, // CREATED_AT
  number, // ENGAGEMENT_SCORE
  any[], // MEDIA
  number // RN
];

interface TweetGetRepliesItem {
  tweetId: string; // 推文ID
  content: string; // 推文内容（CLOB需转字符串）
  authorId: string; // 作者ID
  username: string; // 作者用户名
  displayName: string; // 作者显示名
  avatarUrl: string; // 作者头像
  isVerified: number; // 是否认证
  replyToTweetId: string; // 回复的推文ID
  retweetOfTweetId: string; // 转发的推文ID
  quoteTweetId: string; // 引用的推文ID
  isRetweet: number; // 是否为转发
  isQuoteTweet: number; // 是否为引用
  likesCount: number; // 点赞数
  retweetsCount: number; // 转发数
  repliesCount: number; // 回复数
  viewsCount: number; // 浏览量
  visibility: string; // 可见性
  language: string; // 语言
  createdAt: string; // 创建时间
  engagementScore: number; // 互动分数
  media: any[]; // 媒体文件数组
  rn: number; // 行号
}

interface TweetRepliesResponse extends Response {
  success: true;
  message: string;
  data: {
    page: number; // 当前页码
    pageSize: number; // 每页数量
    tweets: TweetGetRepliesItem[]; // 推文列表
    totalCount?: number; // 总推文数（可选）
  };
  code: 200;
  timestamp: string;
}

// ========================== [tweetId].retweets.get ======================================

interface TweetRetweetsPayload {
  page: number; // 页码
  pageSize: number; // 每页数量
}

type TweetGetRetweetsRow = [
  string, // TWEET_ID
  any, // CONTENT
  string, // AUTHOR_ID
  string, // USERNAME
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  number, // IS_VERIFIED
  string, // REPLY_TO_TWEET_ID
  string, // RETWEET_OF_TWEET_ID
  string, // QUOTE_TWEET_ID
  number, // IS_RETWEET
  number, // IS_QUOTE_TWEET
  number, // LIKES_COUNT
  number, // RETWEETS_COUNT
  number, // REPLIES_COUNT
  number, // VIEWS_COUNT
  string, // VISIBILITY
  string, // LANGUAGE
  string, // CREATED_AT
  number, // ENGAGEMENT_SCORE
  any[], // MEDIA
  number // RN
];

interface TweetGetRetweetsItem {
  tweetId: string; // 推文ID
  content: string; // 推文内容（CLOB需转字符串）
  authorId: string; // 作者ID
  username: string; // 作者用户名
  displayName: string; // 作者显示名
  avatarUrl: string; // 作者头像
  isVerified: number; // 是否认证
  replyToTweetId: string; // 回复的推文ID
  retweetOfTweetId: string; // 转发的推文ID
  quoteTweetId: string; // 引用的推文ID
  isRetweet: number; // 是否为转发
  isQuoteTweet: number; // 是否为引用
  likesCount: number; // 点赞数
  retweetsCount: number; // 转发数
  repliesCount: number; // 回复数
  viewsCount: number; // 浏览量
  visibility: string; // 可见性
  language: string; // 语言
  createdAt: string; // 创建时间
  engagementScore: number; // 互动分数
  media: any[]; // 媒体文件数组
  rn: number; // 行号
}

interface TweetRetweetsResponse extends Response {
  success: true;
  message: string;
  data: {
    page: number; // 当前页码
    pageSize: number; // 每页数量
    tweets: TweetGetRetweetsItem[]; // 推文列表
    totalCount?: number; // 总推文数（可选）
  };
  code: 200;
  timestamp: string;
}

// ========================== [tweetId].likes.get ======================================

interface TweetLikesPayload {
  page: number; // 页码
  pageSize: number; // 每页数量
}

type TweetGetReLikesRow = [
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  string, // LIKE_TYPE
  number // RN
];

interface TweetGetReLikesItem {
  displayName: string; // 显示名
  avatarUrl: string; // 头像URL
  likeType: string; // 点赞类型（如：like, love, etc.）
  rn: number; // 行号
}

interface TweetGetReLikesResponse extends Response {
  success: true;
  message: string;
  data: {
    page: number; // 当前页码
    pageSize: number; // 每页数量
    likes: TweetGetReLikesItem[]; // 推文列表
    totalCount?: number; // 总推文数（可选）
  };
  code: 200;
  timestamp: string;
}

// ========================== [tweetId].comments.get ======================================

interface TweetCommentsPayload {
  page: number; // 页码
  pageSize: number; // 每页数量
  sort: 'newest' | 'oldest' | 'popular'; // 排序方式
}

type TweetGetCommentsRow = [
  string, // COMMENT_ID
  string, // TWEET_ID
  any, // CONTENT
  string, // USER_ID
  string, // PARENT_COMMENT_ID
  string, // USERNAME
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  number, // IS_VERIFIED
  string, // CREATED_AT
  number, // LIKES_COUNT
  number // RN
];

interface TweetGetCommentsItem {
  commentId: string; // 评论ID
  tweetId: string; // 推文ID
  content: string; // 评论内容
  userId: string; // 用户ID
  parentCommentId: string; // 父评论ID
  username: string; // 用户名
  displayName: string; // 显示名
  avatarUrl: string; // 头像URL
  isVerified: number; // 是否认证
  createdAt: string; // 创建时间
  likesCount: number; // 点赞数
  rn: number; // 行号
}

interface TweetGetCommentsResponse extends Response {
  success: true;
  message: string;
  data: {
    page: number; // 当前页码
    pageSize: number; // 每页数量
    sort: 'newest' | 'oldest' | 'popular'; // 排序方式
    comments: TweetGetCommentsItem[]; // 推文列表
    totalCount?: number; // 总推文数（可选）
  };
  code: 200;
  timestamp: string;
}

// ========================== [tweetId].upload.get ======================================

// 上传的单个文件信息类型
interface UploadedFileInfo {
  fileName: string;
  originalName: string;
  url: string;
  size: number;
  mimeType: string;
  mediaType:
    | 'image'
    | 'gif'
    | 'video'
    | 'audio'
    | 'unknown';
  width?: number;
  height?: number;
  duration?: number;
  thumbnailPath?: string;
}

// 媒体上传成功响应数据类型
interface MediaUploadData {
  tweetId: string;
  uploadedFiles: UploadedFileInfo[];
  altText?: string;
  description?: string;
}

// 媒体上传成功响应类型
interface SuccessUploadResponse {
  code: 200;
  success: true;
  message: string;
  data: MediaUploadData;
  timestamp: string;
}

// 通用错误响应类型
interface ErrorResponse {
  success: false;
  message: string;
  code: number;
  timestamp: string;
}

// 媒体上传 API 响应联合类型
type MediaUploadResponse =
  | SuccessUploadResponse
  | ErrorResponse;
