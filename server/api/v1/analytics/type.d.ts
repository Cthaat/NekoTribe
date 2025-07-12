// ========================== user/stat.get ======================================

type UserEngagementStatsRow = [
  string, // userId
  string, // username
  string, // displayName
  number, // totalTweets
  number, // tweetsThisWeek
  number, // tweetsThisMonth
  number, // totalLikesReceived
  number, // avgLikesPerTweet
  number, // totalLikesGiven
  number, // totalCommentsMade
  number // engagementScore
];

// 用户互动统计响应类型
interface UserEngagementStatsItem {
  userId: string;
  username: string;
  displayName: string;
  totalTweets: number;
  tweetsThisWeek: number;
  tweetsThisMonth: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

interface UserEngagementStatsSuccessResponse {
  success: boolean;
  message: string;
  data: {
    user: UserEngagementStatsItem;
  };
  code: number;
  timestamp: string;
}

interface UserEngagementStatsErrorResponse {
  success: boolean;
  message: string;
  code: number;
  timestamp: string;
}

// ========================== tweet/stat.get ======================================

type TweetInteractionRow = [
  number, // tweetId
  any, // content
  number, // authorId
  string, // author
  string, // createdAt
  string | null, // likedByUsers
  string | null, // retweetedByUsers
  number // commentsCount
];

interface TweetInteractionItem {
  tweetId: number;
  content: string;
  authorId: number;
  author: string;
  createdAt: string;
  likedByUsers: string | null;
  retweetedByUsers: string | null;
  commentsCount: number;
}

interface TweetInteractionsSuccessResponse {
  success: boolean;
  message: string;
  data: {
    tweets: TweetInteractionItem[];
    type: string;
    page: number;
    pagesize: number;
    total: number;
  };
  code: number;
  timestamp: string;
}

interface TweetInteractionsErrorResponse {
  success: boolean;
  message: string;
  code: number;
  timestamp: string;
}
