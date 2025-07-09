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

// ========================== list.get ======================================

interface TweetListPayload {
  type: 'home' | 'user' | 'my_tweets' | 'mention' | 'trending'; // 推文类型
  page: number; // 页码
  pageSize: number; // 每页数量
  userId?: string; // 用户ID（仅在type为'user'时需要）
}

type TweetRow = [
  string, // TWEET_ID
  any, // CONTENT (CLOB类型，可能需要异步读取)
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
  number // RN
];

interface TweetItem {
  tweetId: string; // 推文ID
  content: string; // 推文内容（已转为字符串）
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
}

interface TweetListResponse extends Response {
  success: true;
  message: string;
  data: {
    tweets: TweetItem[]; // 推文列表
  };
  code: 200;
  timestamp: string;
}
