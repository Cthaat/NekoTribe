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
