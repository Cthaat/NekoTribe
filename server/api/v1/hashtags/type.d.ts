// ========================== trending.get ======================================

// 热门话题数据类型
interface TrendingHashtag {
  hashtag_id: number;
  tag_name: string;
  usage_count: number;
  trending_score: number;
}

type TrendingHashtagsDataRow = [
  number, // hashtag_id
  string, // tag_name
  number, // usage_count
  number // trending_score
];

// 热门话题响应数据类型
interface TrendingHashtagsData {
  trending_hashtags: TrendingHashtag[];
  updated_at: string;
}

// 热门话题成功响应类型
interface TrendingHashtagsSuccessResponse {
  success: true;
  message: string;
  data: TrendingHashtagsData;
  code: 200;
}

// 热门话题错误响应类型
interface TrendingHashtagsErrorResponse {
  success: false;
  message: string;
  code: number;
}

// 热门话题API响应联合类型
type TrendingHashtagsResponse =
  | TrendingHashtagsSuccessResponse
  | TrendingHashtagsErrorResponse;

// ========================== {tag}/tweets.get ======================================

interface TweetListPayload {
  page: number; // 页码
  pageSize: number; // 每页数量
  sort: 'popular' | 'newest' | 'oldest'; // 排序方式
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
  number // RN
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
}

interface TagTweetListResponse {
  success: true;
  message: string;
  data: {
    sort: 'popular' | 'newest' | 'oldest'; // 排序方式
    page: number; // 当前页码
    pageSize: number; // 每页数量
    tweets: TweetItem[]; // 推文列表
    totalCount: number; // 总数
  };
  code: 200;
  timestamp: string;
}

// ========================== search.get ======================================

interface SearchPayload {
  q: string; // 搜索关键词
  limit: number; // 返回数量限制
}

type HashtagSearchItemRow = [
  number, // hashtagId
  string, // tagName
  string, // tagNameLower
  number, // usageCount
  number, // trendingScore
  number, // isTrending
  string, // createdAt
  string, // updatedAt
  number // relevanceScore
];

// 搜索结果项类型
interface HashtagSearchItem {
  hashtagId: number;
  tagName: string;
  tagNameLower: string;
  usageCount: number;
  trendingScore: number;
  isTrending: number;
  createdAt: string;
  updatedAt: string;
  relevanceScore?: number;
}

// 搜索响应类型
interface HashtagSearchResponse {
  success: true;
  message: string;
  data: {
    hashtags: HashtagSearchItem[];
    query: string;
    limit: number;
  };
  code: 200;
  timestamp: string;
}
