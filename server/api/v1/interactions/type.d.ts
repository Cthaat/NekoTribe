// ========================== like.post ======================================

interface LikePayload {
  tweetId: string;
  likeType: 'like' | 'unlike';
}
