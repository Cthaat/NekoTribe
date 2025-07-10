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
