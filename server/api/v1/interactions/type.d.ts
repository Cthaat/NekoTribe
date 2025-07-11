// ========================== like.post ======================================

interface LikePayload {
  tweetId: string;
  likeType: 'like' | 'unlike' | 'likeComment' | 'unlikeComment';
}

// ========================== bookmark.post ======================================

interface BookmarkPayload {
  tweetId: string;
  bookmarkType: 'mark' | 'unmark';
}
