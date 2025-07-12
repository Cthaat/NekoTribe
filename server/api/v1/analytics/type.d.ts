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
    users: UserEngagementStatsItem[];
    type: string;
    limit: number;
    total: number;
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
