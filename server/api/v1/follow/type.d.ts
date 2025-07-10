// ========================== action.post ======================================

interface FollowActionPayload {
  userId: string; // 用户ID
  action: 'follow' | 'unfollow' | 'block' | 'unblock'; // 操作类型
}

interface FollowActionResponse extends Response {
  success: boolean;
  message: string;
  data: {
    tweetId: string;
  };
  code: number;
  timestamp: string;
}

// ========================== [userId].following.get ======================================

interface TweetFollowingPayload {
  page: number; // 页码
  pageSize: number; // 每页数量
}

type TweetGetFollowingRow = [
  string, // 显示名称
  string, // 头像 URL
  number // 行号
];

interface TweetGetFollowingItem {
  displayName: string; // 显示名称
  avatarUrl: string; // 头像 URL
  rn: number; // 行号
}

interface TweetGetFollowingResponse extends Response {
  success: boolean;
  data: {
    list: TweetGetFollowingItem[]; // 关注列表
    totalCount: number; // 总数
  };
  code: number;
  timestamp: string;
}

// ========================== [userId].follower.get ======================================

interface TweetFollowerPayload {
  page: number; // 页码
  pageSize: number; // 每页数量
}

type TweetGetFollowerRow = [
  string, // 显示名称
  string, // 头像 URL
  number // 行号
];

interface TweetGetFollowerItem {
  displayName: string; // 显示名称
  avatarUrl: string; // 头像 URL
  rn: number; // 行号
}

interface TweetGetFollowerResponse extends Response {
  success: boolean;
  data: {
    list: TweetGetFollowerItem[]; // 关注列表
    totalCount: number; // 总数
  };
  code: number;
  timestamp: string;
}





