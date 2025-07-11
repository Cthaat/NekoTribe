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

// ========================== [tag].stats ======================================

// 统计查询参数类型
interface HashtagStatisticsPayload {
  type: 'all' | 'trending' | 'statistics'; // 查询类型
  limit: number; // 返回数量限制
}

// 统计数据库行类型 (v_hashtag_statistics 视图)
type HashtagStatisticsRow = [
  number, // HASHTAG_ID
  string, // TAG_NAME
  string, // TAG_NAME_LOWER
  number, // USAGE_COUNT
  number, // TRENDING_SCORE
  number, // IS_TRENDING
  string, // CREATED_AT
  string, // UPDATED_AT
  number, // TOTAL_TWEETS
  number, // TOTAL_AUTHORS
  number, // TOTAL_LIKES
  number, // TOTAL_RETWEETS
  number, // TOTAL_REPLIES
  number, // TOTAL_VIEWS
  number, // AVG_ENGAGEMENT_SCORE
  number, // TWEETS_TODAY
  number, // TWEETS_THIS_WEEK
  number, // TWEETS_THIS_MONTH
  number, // LIKES_TODAY
  number, // RETWEETS_TODAY
  number, // REPLIES_TODAY
  number, // ACTIVE_AUTHORS_TODAY
  number, // ACTIVE_AUTHORS_THIS_WEEK
  number, // WEEKLY_GROWTH_RATE
  number, // AVG_LIKE_RATE
  number, // AVG_RETWEET_RATE
  number, // DAILY_HOTNESS_SCORE
  number, // LATEST_TWEET_ID
  string, // LATEST_TWEET_CREATED_AT
  number, // LATEST_TWEET_AUTHOR_ID
  number, // HOTTEST_TWEET_ID
  number // HOTTEST_TWEET_ENGAGEMENT_SCORE
];

// 趋势数据库行类型 (v_hashtag_trends 视图)
type HashtagTrendsRow = [
  number, // HASHTAG_ID
  string, // TAG_NAME
  string, // TAG_NAME_LOWER
  number, // IS_TRENDING
  number, // TWEETS_LAST_24H
  number, // TWEETS_LAST_7D
  number, // TWEETS_LAST_30D
  number, // LIKES_LAST_24H
  number, // RETWEETS_LAST_24H
  number, // REPLIES_LAST_24H
  number, // UNIQUE_AUTHORS_LAST_24H
  number, // UNIQUE_AUTHORS_LAST_7D
  number, // DAILY_VELOCITY
  number, // WEEKLY_VELOCITY
  number, // MOMENTUM_SCORE
  number, // DAILY_RANK
  number, // WEEKLY_RANK
  number, // MOMENTUM_RANK
  string, // TREND_CATEGORY
  string // CALCULATED_AT
];

// 统计结果项类型
interface HashtagStatisticsItem {
  hashtagId: number; // 话题ID
  tagName: string; // 话题名称
  tagNameLower: string; // 话题名称小写
  usageCount: number; // 使用次数
  trendingScore: number; // 趋势分数
  isTrending: number; // 是否热门 0-否 1-是
  createdAt: string; // 创建时间
  updatedAt: string; // 更新时间
  totalTweets: number; // 总推文数
  totalAuthors: number; // 总作者数
  totalLikes: number; // 总点赞数
  totalRetweets: number; // 总转发数
  totalReplies: number; // 总回复数
  totalViews: number; // 总浏览数
  avgEngagementScore: number; // 平均互动分数
  tweetsToday: number; // 今日推文数
  tweetsThisWeek: number; // 本周推文数
  tweetsThisMonth: number; // 本月推文数
  likesToday: number; // 今日点赞数
  retweetsToday: number; // 今日转发数
  repliesToday: number; // 今日回复数
  activeAuthorsToday: number; // 今日活跃作者数
  activeAuthorsThisWeek: number; // 本周活跃作者数
  weeklyGrowthRate: number; // 周增长率
  avgLikeRate: number; // 平均点赞率
  avgRetweetRate: number; // 平均转发率
  dailyHotnessScore: number; // 日热度分数
  latestTweetId: number; // 最新推文ID
  latestTweetCreatedAt: string; // 最新推文时间
  latestTweetAuthorId: number; // 最新推文作者ID
  hottestTweetId: number; // 最热推文ID
  hottestTweetEngagementScore: number; // 最热推文互动分数
}

// 趋势结果项类型
interface HashtagTrendsItem {
  hashtagId: number; // 话题ID
  tagName: string; // 话题名称
  tagNameLower: string; // 话题名称小写
  isTrending: number; // 是否热门 0-否 1-是
  tweetsLast24h: number; // 24小时推文数
  tweetsLast7d: number; // 7天推文数
  tweetsLast30d: number; // 30天推文数
  likesLast24h: number; // 24小时点赞数
  retweetsLast24h: number; // 24小时转发数
  repliesLast24h: number; // 24小时回复数
  uniqueAuthorsLast24h: number; // 24小时活跃作者数
  uniqueAuthorsLast7d: number; // 7天活跃作者数
  dailyVelocity: number; // 日速度
  weeklyVelocity: number; // 周速度
  momentumScore: number; // 动量分数
  dailyRank: number; // 日排名
  weeklyRank: number; // 周排名
  momentumRank: number; // 动量排名
  trendCategory: string; // 趋势分类
  calculatedAt: string; // 计算时间
}

// 统计成功响应类型
interface HashtagStatisticsSuccessResponse {
  success: true;
  message: string;
  data: {
    hashtags: HashtagStatisticsItem[] | HashtagTrendsItem[];
    type: string;
    limit: number;
    total: number;
  };
  code: 200;
  timestamp: string;
}

// 统计失败响应类型
interface HashtagStatisticsErrorResponse {
  success: false;
  message: string;
  code: number;
  timestamp: string;
}

// 统计响应联合类型
type HashtagStatisticsResponse =
  | HashtagStatisticsSuccessResponse
  | HashtagStatisticsErrorResponse;
